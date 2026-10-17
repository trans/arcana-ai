require "http/client"
require "json"

module Arcana::AI
  module Chat
    class OpenAI < Provider
      ENDPOINT = "https://api.openai.com/v1/chat/completions"

      getter model : String

      # The service behind the endpoint: "openai", or for an OpenAI-
      # compatible service, its own name ("grok", "deepseek"). Responses
      # carry it as their `provider`, and `Pricing` looks rates up by it.
      getter name : String

      def initialize(
        @api_key : String,
        @model : String = "gpt-4o-mini",
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
        @name : String = "openai",
      )
        raise ConfigError.new("API key is required for OpenAI Chat") if @api_key.strip.empty?
        @trace = trace
      end

      def models : Array(String)
        uri = URI.parse(@endpoint)
        models_uri = URI.new(scheme: uri.scheme, host: uri.host, port: uri.port, path: "/v1/models")
        headers = Util.bearer_headers(@api_key)
        response = HTTP::Client.get(models_uri, headers: headers)
        return [] of String unless response.success?
        parsed = JSON.parse(response.body)
        data = parsed["data"]?.try(&.as_a?) || return [] of String
        data.compact_map { |m| m["id"]?.try(&.as_s?) }.sort
      rescue
        [] of String
      end

      def complete(request : Request) : Response
        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)

        emit_request_trace(request, model, payload)

        response, stats = retry_policy.run(on_retry: retry_tracer(request)) do
          r = post_api(payload)
          emit_response_trace(request, r)
          raise APIError.from(r, r.body, "openai:chat") unless r.success?
          r
        end

        result = Response.from_openai_json(response.body, provider: name)
        result.raw_request = payload
        result.with_retries(stats)
      end

      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model, stream: true)
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
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
        tool_calls_map = {} of Int32 => {id: String, name: String, arguments: String::Builder}
        response_model = ""
        finish_reason = ""
        usage_json : JSON::Any? = nil
        service_tier : String? = nil

        stats = RetryStats.new
        begin
          _, stats = retry_policy.run(ctx, retry_tracer(request)) do |attempt|
            client.post(uri.request_target, headers: headers, body: payload) do |response|
              unless response.success?
                body = response.body_io.gets_to_end
                raise APIError.from(response, body, "openai:chat:stream")
              end
              attempt.started! # past this point, a failure can't be retried

              response.body_io.each_line do |line|
                raise CancelledError.new if ctx.try(&.cancelled?)

                next unless line.starts_with?("data: ")
                data = line[6..]
                next if data == "[DONE]"

                parsed = JSON.parse(data) rescue next

                if m = parsed["model"]?.try(&.as_s?)
                  response_model = m
                end
                if t = parsed["service_tier"]?.try(&.as_s?)
                  service_tier = t
                end

                # The last chunk carries the usage with no choices, so it
                # mustn't end the iteration early.
                if choice = parsed["choices"]?.try(&.as_a?).try(&.first?)
                  if fr = choice["finish_reason"]?.try(&.as_s?)
                    finish_reason = fr
                  end

                  if delta = choice["delta"]?
                    # Text content
                    if text = delta["content"]?.try(&.as_s?)
                      content << text
                      block.call(StreamEvent.text_delta(text))
                    end

                    # Tool calls
                    if tcs = delta["tool_calls"]?.try(&.as_a?)
                      tcs.each do |tc|
                        idx = tc["index"]?.try(&.as_i?) || 0
                        unless tool_calls_map.has_key?(idx)
                          tool_calls_map[idx] = {
                            id:        tc["id"]?.try(&.as_s?) || "",
                            name:      tc["function"]?.try { |f| f["name"]?.try(&.as_s?) } || "",
                            arguments: String::Builder.new,
                          }
                        end
                        if args = tc["function"]?.try { |f| f["arguments"]?.try(&.as_s?) }
                          tool_calls_map[idx][:arguments] << args
                        end
                      end
                    end
                  end
                end

                if (usage = parsed["usage"]?) && usage.as_h?
                  usage_json = usage
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

        tool_calls = tool_calls_map.to_a.sort_by(&.[0]).map do |_, tc|
          call = ToolCall.new(
            id: tc[:id],
            type: "function",
            function: ToolCall::FunctionCall.new(
              name: tc[:name],
              arguments: (args_str = tc[:arguments].to_s).empty? ? "{}" : args_str,
            ),
          )
          block.call(StreamEvent.tool_use(call))
          call
        end

        content_str = content.to_s

        final = Response.new(
          content: content_str.empty? ? nil : content_str,
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          model: response_model,
          provider: name,
          raw_request: payload,
          raw_json: "",
          usage: Usage.from_openai(usage_json, service_tier),
        )

        final = final.with_retries(stats)
        block.call(StreamEvent.done(final))
        final
      end

      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?

        model = request.model.empty? ? @model : request.model
        payload = build_payload(request, model)
        emit_request_trace(request, model, payload)

        response, stats = retry_policy.run(ctx, retry_tracer(request)) do
          r = post_api_cancellable(payload, ctx)
          emit_response_trace(request, r)
          raise APIError.from(r, r.body, "openai:chat") unless r.success?
          r
        end

        result = Response.from_openai_json(response.body, provider: name)
        result.raw_request = payload
        result.with_retries(stats)
      end

      private def build_payload(request : Request, model : String, stream : Bool = false) : String
        # OpenAI takes `max_completion_tokens` for every model, and the
        # o-series and every model from gpt-5 on reject `max_tokens`.
        # OpenAI-compatible services keep `max_tokens`, except for
        # reasoning requests. Reasoning requests also take a
        # `reasoning_effort` param.
        reasoning = request.thinking
        reasoning = nil unless reasoning && reasoning.enabled
        completion_tokens = name == "openai" || reasoning

        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "stream", true if stream
            json.field "stream_options", JSON.parse(%({"include_usage": true})) if stream
            json.field "messages" do
              json.array do
                request.messages.each(&.to_json(json))
              end
            end
            json.field "temperature", request.temperature if send_temperature?(request, model)

            json.field completion_tokens ? "max_completion_tokens" : "max_tokens", request.max_tokens
            json.field "reasoning_effort", reasoning.effort || "medium" if reasoning

            if tools = request.tools
              json.field "tools" do
                json.array do
                  tools.each(&.to_json(json))
                end
              end
              json.field "tool_choice", request.tool_choice || "auto"
            end
          end
        end
      end

      # Most of OpenAI's models from gpt-5 on, and the o-series, take
      # only their own default temperature (1) and reject any other. So
      # the request's default (0.7) goes only to the GPT-4 and GPT-3.5
      # models, which have always had it, and to compatible services. A
      # temperature the caller picked always goes.
      private def send_temperature?(request : Request, model : String) : Bool
        return true unless name == "openai" && request.temperature == 0.7
        base = model.lchop("ft:")
        base.starts_with?("gpt-4") || base.starts_with?("gpt-3.5")
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def post_api_cancellable(payload : String, ctx : Context) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
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
          provider:   name,
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
          provider:       name,
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
