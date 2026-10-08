require "http/client"
require "json"

module Arcana::AI
  module Chat
    class Gemini < Provider
      ENDPOINT      = "https://generativelanguage.googleapis.com/v1beta"
      DEFAULT_MODEL = "gemini-2.5-flash"

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = DEFAULT_MODEL,
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for Gemini Chat") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "gemini"
      end

      def models : Array(String)
        uri = URI.parse("#{@endpoint}/models")
        headers = HTTP::Headers{"x-goog-api-key" => @api_key}
        response = HTTP::Client.get(uri, headers: headers)
        return [] of String unless response.success?
        parsed = JSON.parse(response.body)
        models = parsed["models"]?.try(&.as_a?) || return [] of String
        models.compact_map { |m| m["name"]?.try(&.as_s?).try(&.sub("models/", "")) }.sort
      rescue
        [] of String
      end

      def complete(request : Request) : Response
        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        emit_request_trace(request, model, payload)

        response, stats = retry_policy.run(on_retry: retry_tracer(request)) do
          r = post_api(model, payload)
          emit_response_trace(request, r)
          raise APIError.from(r, r.body, "gemini:chat") unless r.success?
          r
        end

        parse_response(response.body, payload).with_retries(stats)
      end

      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        emit_request_trace(request, model, payload)

        response, stats = retry_policy.run(ctx, retry_tracer(request)) do
          r = post_api_cancellable(model, payload, ctx)
          emit_response_trace(request, r)
          raise APIError.from(r, r.body, "gemini:chat") unless r.success?
          r
        end

        parse_response(response.body, payload).with_retries(stats)
      end

      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        headers = HTTP::Headers{
          "x-goog-api-key" => @api_key,
          "Content-Type"   => "application/json",
        }
        uri = URI.parse("#{@endpoint}/models/#{model}:streamGenerateContent?alt=sse")
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        # The watcher stops when the stream ends, so it doesn't outlive the call.
        streaming = true
        if c = ctx
          spawn do
            while streaming && !c.cancelled?
              sleep 100.milliseconds
            end
            if streaming
              client.close rescue nil
            end
          end
        end

        content = String::Builder.new
        tool_calls = [] of ToolCall
        response_model = model
        finish_reason = ""
        prompt_tokens = 0
        completion_tokens = 0

        stats = RetryStats.new
        begin
          _, stats = retry_policy.run(ctx, retry_tracer(request)) do |attempt|
            client.post(uri.request_target, headers: headers, body: payload) do |response|
              unless response.success?
                body = response.body_io.gets_to_end
                raise APIError.from(response, body, "gemini:chat:stream")
              end
              attempt.started! # past this point, a failure can't be retried

              response.body_io.each_line do |line|
                raise CancelledError.new if ctx.try(&.cancelled?)

                next unless line.starts_with?("data: ")
                data = line[6..]
                next if data.empty?

                parsed = JSON.parse(data) rescue next

                if candidates = parsed["candidates"]?.try(&.as_a?)
                  candidate = candidates[0]?
                  next unless candidate

                  if fr = candidate["finishReason"]?.try(&.as_s?)
                    finish_reason = normalize_finish_reason(fr)
                  end

                  if parts = candidate["content"]?.try { |c| c["parts"]?.try(&.as_a?) }
                    parts.each do |part|
                      if text = part["text"]?.try(&.as_s?)
                        content << text
                        block.call(StreamEvent.text_delta(text))
                      elsif fc = part["functionCall"]?
                        tc = ToolCall.new(
                          id: Random::Secure.hex(12),
                          type: "function",
                          function: ToolCall::FunctionCall.new(
                            name: fc["name"]?.try(&.as_s?) || "",
                            arguments: (fc["args"]? || JSON::Any.new({} of String => JSON::Any)).to_json,
                          ),
                        )
                        tool_calls << tc
                        block.call(StreamEvent.tool_use(tc))
                      end
                    end
                  end
                end

                if usage = parsed["usageMetadata"]?
                  prompt_tokens = usage["promptTokenCount"]?.try(&.as_i?) || prompt_tokens
                  completion_tokens = usage["candidatesTokenCount"]?.try(&.as_i?) || completion_tokens
                end
              end
            end
          end
        rescue ex : CancelledError
          raise ex
        rescue ex : IO::Error
          raise CancelledError.new if ctx.try(&.cancelled?)
          raise ex
        ensure
          streaming = false
        end

        content_str = content.to_s

        final = Response.new(
          content: content_str.empty? ? nil : content_str,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: response_model,
          provider: "gemini",
          raw_request: payload,
          raw_json: "",
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
        )

        final = final.with_retries(stats)
        block.call(StreamEvent.done(final))
        final
      end

      private def build_payload(request : Request, model : String) : String
        JSON.build do |json|
          json.object do
            # System instruction (separate from contents)
            system_msg = request.messages.find { |m| m.role == "system" }
            if system_msg && (sys_content = system_msg.content)
              json.field "systemInstruction" do
                json.object do
                  json.field "parts" do
                    json.array do
                      json.object { json.field "text", sys_content }
                    end
                  end
                end
              end
            end

            # Contents (conversation messages)
            json.field "contents" do
              json.array do
                request.messages.each do |msg|
                  next if msg.role == "system"
                  build_content(json, msg)
                end
              end
            end

            # Generation config
            json.field "generationConfig" do
              json.object do
                json.field "temperature", request.temperature
                json.field "maxOutputTokens", request.max_tokens if request.max_tokens > 0

                # Gemini 2.5 series: thinkingConfig controls the reasoning
                # budget and whether thought parts come back in the
                # response. Emit only when the caller opted in.
                if think = request.thinking
                  if think.enabled
                    json.field "thinkingConfig" do
                      json.object do
                        if budget = think.budget
                          json.field "thinkingBudget", budget
                        end
                        json.field "includeThoughts", think.include_thoughts
                      end
                    end
                  end
                end
              end
            end

            # Tools (function declarations)
            if tools = request.tools
              json.field "tools" do
                json.array do
                  json.object do
                    json.field "functionDeclarations" do
                      json.array do
                        tools.each do |tool|
                          json.object do
                            json.field "name", tool.name
                            json.field "description", tool.description
                            json.field "parameters", JSON.parse(tool.parameters_json)
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def build_content(json : JSON::Builder, msg : Message) : Nil
        json.object do
          role = case msg.role
                 when "assistant" then "model"
                 when "tool"      then "user"
                 else                  msg.role
                 end
          json.field "role", role

          json.field "parts" do
            json.array do
              if msg.tool_call_id && (content = msg.content)
                # Tool result — send as functionResponse
                json.object do
                  json.field "functionResponse" do
                    json.object do
                      json.field "name", msg.name || msg.tool_call_id || ""
                      json.field "response", JSON.parse(content) rescue JSON::Any.new({"result" => JSON::Any.new(content)})
                    end
                  end
                end
              elsif tc = msg.tool_calls
                # Assistant message with tool calls
                if c = msg.content
                  json.object { json.field "text", c }
                end
                tc.each do |tool_call|
                  json.object do
                    json.field "functionCall" do
                      json.object do
                        json.field "name", tool_call.function.name
                        json.field "args", JSON.parse(tool_call.function.arguments)
                      end
                    end
                  end
                end
              else
                msg.images.try &.each do |img|
                  inline = img.inline ||
                           raise ConfigError.new("Gemini can't fetch image URLs; pass the image's bytes (ImagePart.bytes or ImagePart.file)")
                  json.object do
                    json.field "inlineData" do
                      json.object do
                        json.field "mimeType", inline[0]
                        json.field "data", inline[1]
                      end
                    end
                  end
                end
                json.object { json.field "text", msg.content || "" }
              end
            end
          end
        end
      end

      private def parse_response(body : String, payload : String) : Response
        parsed = JSON.parse(body)

        content = nil
        tool_calls = [] of ToolCall
        thinking_parts = [] of String

        if candidates = parsed["candidates"]?.try(&.as_a?)
          candidate = candidates[0]?
          if candidate
            finish_reason = normalize_finish_reason(candidate["finishReason"]?.try(&.as_s?) || "")

            if parts = candidate["content"]?.try { |c| c["parts"]?.try(&.as_a?) }
              parts.each do |part|
                # Thought parts (Gemini 2.5 with includeThoughts) come
                # back with `thought: true`. Split them out so callers
                # get the reasoning separately from the final answer.
                is_thought = part["thought"]?.try(&.as_bool?) == true
                if text = part["text"]?.try(&.as_s?)
                  if is_thought
                    thinking_parts << text
                  else
                    content = content ? content + text : text
                  end
                elsif fc = part["functionCall"]?
                  tool_calls << ToolCall.new(
                    id: Random::Secure.hex(12),
                    type: "function",
                    function: ToolCall::FunctionCall.new(
                      name: fc["name"]?.try(&.as_s?) || "",
                      arguments: (fc["args"]? || JSON::Any.new({} of String => JSON::Any)).to_json,
                    ),
                  )
                end
              end
            end
          end
        end

        finish_reason ||= ""

        usage = parsed["usageMetadata"]?
        prompt_tokens = usage.try { |u| u["promptTokenCount"]?.try(&.as_i?) }
        completion_tokens = usage.try { |u| u["candidatesTokenCount"]?.try(&.as_i?) }
        # Gemini reports thoughts token count separately when thinking ran.
        reasoning_tokens = usage.try { |u| u["thoughtsTokenCount"]?.try(&.as_i?) }

        thinking_content = thinking_parts.empty? ? nil : thinking_parts.join("\n\n")

        Response.new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: parsed["modelVersion"]?.try(&.as_s?) || "",
          provider: "gemini",
          raw_request: payload,
          raw_json: body,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          thinking_content: thinking_content,
          reasoning_tokens: reasoning_tokens,
        )
      end

      private def normalize_finish_reason(reason : String) : String
        case reason
        when "STOP"       then "stop"
        when "MAX_TOKENS" then "length"
        when "SAFETY"     then "safety"
        when "RECITATION" then "recitation"
        else                   reason.downcase
        end
      end

      private def post_api(model : String, payload : String) : HTTP::Client::Response
        headers = HTTP::Headers{
          "x-goog-api-key" => @api_key,
          "Content-Type"   => "application/json",
        }
        uri = URI.parse("#{@endpoint}/models/#{model}:generateContent")
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def post_api_cancellable(model : String, payload : String, ctx : Context) : HTTP::Client::Response
        headers = HTTP::Headers{
          "x-goog-api-key" => @api_key,
          "Content-Type"   => "application/json",
        }
        uri = URI.parse("#{@endpoint}/models/#{model}:generateContent")
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        result = Channel(HTTP::Client::Response | Exception).new(1)

        spawn do
          begin
            resp = client.post(uri.request_target, headers: headers, body: payload)
            result.send(resp)
          rescue ex
            result.send(ex)
          end
        end

        finished = false
        spawn do
          until ctx.cancelled? || finished
            sleep 100.milliseconds
          end
          next if finished
          client.close rescue nil
          result.send(CancelledError.new) rescue nil
        end

        outcome = result.receive
        finished = true
        case outcome
        when Exception
          raise outcome
        when HTTP::Client::Response
          outcome
        else
          raise CancelledError.new
        end
      end

      private def emit_request_trace(request : Request, model : String, payload : String) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:      "api_request_chat",
          event_type: "api_request",
          provider:   "gemini",
          endpoint:   @endpoint,
          model:      model,
          tags:       tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_chat",
          event_type:     "api_response",
          provider:       "gemini",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })
      end
    end
  end
end
