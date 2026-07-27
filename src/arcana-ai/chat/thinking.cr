module Arcana::AI
  module Chat
    # Unified representation of chain-of-thought / reasoning knobs
    # across providers. Each provider maps this to its own wire shape:
    #
    #   Anthropic — `thinking: {type: "enabled", budget_tokens: N}`
    #                thinking content surfaced as `type: "thinking"` blocks
    #                in the response's content array.
    #
    #   OpenAI    — `reasoning_effort: "low"|"medium"|"high"` (o-series
    #                reasoning models). Content is NOT surfaced; only the
    #                reasoning token count comes back in
    #                `usage.completion_tokens_details.reasoning_tokens`.
    #
    #   Gemini    — `generationConfig.thinkingConfig: {thinkingBudget: N,
    #                includeThoughts: bool}` (2.5 series). Thought parts
    #                come back with `thought: true` when includeThoughts
    #                is set.
    #
    # Callers can supply what fits their target: `budget` for
    # Anthropic/Gemini, `effort` for OpenAI. Each provider ignores
    # fields it doesn't use and picks a sensible default for its own
    # tier if the caller left them nil.
    struct ThinkingConfig
      getter enabled : Bool
      getter budget : Int32?
      getter effort : String?
      getter include_thoughts : Bool

      def initialize(
        @enabled : Bool = true,
        @budget : Int32? = nil,
        @effort : String? = nil,
        @include_thoughts : Bool = true,
      )
      end

      # Convenience: build from a JSON::Any. Accepts either a bool
      # (`true` = enabled with defaults) or an object with the config
      # fields. Returns nil if the input is anything else — providers
      # treat that as "reasoning off."
      def self.from_json(value : JSON::Any?) : ThinkingConfig?
        return nil if value.nil?
        return ThinkingConfig.new(enabled: true) if value.as_bool? == true
        return nil if value.as_bool? == false
        return nil unless obj = value.as_h?
        new(
          enabled: obj["enabled"]?.try(&.as_bool?).nil? ? true : obj["enabled"].as_bool,
          budget: obj["budget"]?.try(&.as_i?),
          effort: obj["effort"]?.try(&.as_s?),
          include_thoughts: obj["include_thoughts"]?.try(&.as_bool?).nil? ? true : obj["include_thoughts"].as_bool,
        )
      end
    end
  end
end
