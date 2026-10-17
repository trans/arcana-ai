require "json"

module Arcana::AI
  module Chat
    struct Response
      property content : String?
      property tool_calls : Array(ToolCall)
      property finish_reason : String?
      property model : String
      property provider : String
      property raw_request : String  # full request body sent to API
      property raw_json : String     # full response body from API

      # What the call used, in the same billing categories for every
      # provider (see `Usage`); nil when the provider reported none.
      # `Pricing` prices it.
      property usage : Usage?

      # The raw reasoning text if the provider surfaces it (Anthropic
      # extended thinking, Gemini with includeThoughts). OpenAI o-series
      # never surfaces the reasoning itself, so this stays nil for OpenAI
      # even when reasoning ran.
      property thinking_content : String?

      # Server-side tool results (e.g. web_search results).
      property server_tool_results : Array(JSON::Any)

      # Retries the call needed (rate limits, server or network errors)
      # and the time spent waiting between tries. See `RetryPolicy`.
      property retries : Int32 = 0
      property retry_wait : Time::Span = Time::Span.zero

      def initialize(
        @content : String? = nil,
        @tool_calls : Array(ToolCall) = [] of ToolCall,
        @finish_reason : String? = nil,
        @model : String = "",
        @provider : String = "",
        @raw_request : String = "",
        @raw_json : String = "",
        @thinking_content : String? = nil,
        @server_tool_results : Array(JSON::Any) = [] of JSON::Any,
        @usage : Usage? = nil,
      )
      end

      # This response with the retry record of the call that produced it.
      def with_retries(stats : RetryStats) : self
        copy = self
        copy.retries = stats.retries
        copy.retry_wait = stats.waited
        copy
      end

      # Did the model return any tool calls?
      def has_tool_calls? : Bool
        !@tool_calls.empty?
      end

      # Find the first tool call matching a given function name.
      def tool_call(name : String) : ToolCall?
        @tool_calls.find { |tc| tc.function.name == name }
      end

      # Parse from an OpenAI-compatible JSON response body.
      def self.from_openai_json(raw : String, provider : String = "openai") : self
        parsed = JSON.parse(raw)

        choices = parsed["choices"]?.try(&.as_a?)
        unless choices && !choices.empty?
          return new(raw_json: raw, provider: provider)
        end

        message = choices[0]["message"]?
        finish = choices[0]["finish_reason"]?.try(&.as_s?)
        model = parsed["model"]?.try(&.as_s?) || ""

        content = message.try { |m| m["content"]?.try(&.as_s?) }

        tool_calls = [] of ToolCall
        if tcs = message.try { |m| m["tool_calls"]?.try(&.as_a?) }
          tcs.each do |tc|
            fn = tc["function"]?
            next unless fn
            tool_calls << ToolCall.new(
              id: tc["id"]?.try(&.as_s?) || "",
              type: tc["type"]?.try(&.as_s?) || "function",
              function: ToolCall::FunctionCall.new(
                name: fn["name"]?.try(&.as_s?) || "",
                arguments: fn["arguments"]?.try(&.as_s?) || "{}",
              ),
            )
          end
        end

        usage = parsed["usage"]?
        new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: finish,
          model: model,
          provider: provider,
          raw_json: raw,
          usage: Usage.from_openai(usage, parsed["service_tier"]?.try(&.as_s?)),
        )
      end
    end
  end
end
