require "json"

module Arcana::AI
  # What a call used, in the categories providers bill by, the same for
  # every provider. Providers report usage differently (OpenAI's and
  # Gemini's prompt counts include cached tokens, Anthropic's doesn't;
  # Gemini counts thinking apart from output), so each provider fills this
  # in from its own report:
  #
  # - `input`: input tokens billed at the full input rate, never cached ones.
  # - `cache_read`: input tokens read from the provider's prompt cache.
  # - `cache_write`: input tokens written to the cache at the provider's
  #   standard write rate (Anthropic's 5-minute cache, OpenAI's cache).
  # - `cache_write_1h`: input tokens written to Anthropic's 1-hour cache.
  # - `output`: output tokens, reasoning included.
  # - `reasoning`: the part of `output` spent reasoning, when reported.
  # - `web_searches`, `code_executions`: server-side tool calls.
  # - `tier`: the service tier the call ran on, `"standard"` for the
  #   provider's standard tier, nil when not reported.
  # - `geo`: where the provider says it ran the call (Anthropic's
  #   `inference_geo`), when reported.
  #
  # A response carries a `Usage` only when the provider reported one: a nil
  # usage means it didn't, never that the call was free.
  struct Usage
    include JSON::Serializable

    getter input : Int64
    getter cache_read : Int64
    getter cache_write : Int64
    getter cache_write_1h : Int64
    getter output : Int64
    getter reasoning : Int64?
    getter web_searches : Int64
    getter code_executions : Int64
    getter tier : String?
    getter geo : String?

    def initialize(
      @input : Int64 = 0_i64,
      @output : Int64 = 0_i64,
      @cache_read : Int64 = 0_i64,
      @cache_write : Int64 = 0_i64,
      @cache_write_1h : Int64 = 0_i64,
      @reasoning : Int64? = nil,
      @web_searches : Int64 = 0_i64,
      @code_executions : Int64 = 0_i64,
      @tier : String? = nil,
      @geo : String? = nil,
    )
    end

    # The whole prompt: input plus cache reads and writes. Prices that
    # change with prompt length go by this.
    def prompt : Int64
      input + cache_read + cache_write + cache_write_1h
    end

    # Two calls' usage together, as for an embedding run split into
    # batches. The tier and region carry over only when both agree.
    def +(other : Usage) : Usage
      Usage.new(
        input: input + other.input,
        output: output + other.output,
        cache_read: cache_read + other.cache_read,
        cache_write: cache_write + other.cache_write,
        cache_write_1h: cache_write_1h + other.cache_write_1h,
        reasoning: (r = reasoning) && (o = other.reasoning) ? r + o : (reasoning || other.reasoning),
        web_searches: web_searches + other.web_searches,
        code_executions: code_executions + other.code_executions,
        tier: tier == other.tier ? tier : nil,
        geo: geo == other.geo ? geo : nil,
      )
    end

    # From an OpenAI (or compatible) `usage` object, whose `prompt_tokens`
    # include the cached tokens and the cache writes. `service_tier` is
    # the response's own field; OpenAI calls its standard tier "default".
    # Nil when `usage` isn't an object.
    def self.from_openai(usage : JSON::Any?, service_tier : String? = nil) : Usage?
      return unless usage && usage.as_h?
      details = usage["prompt_tokens_details"]?
      cached = count(details, "cached_tokens")
      written = count(details, "cache_write_tokens")
      new(
        input: Math.max(0_i64, count(usage, "prompt_tokens") - cached - written),
        cache_read: cached,
        cache_write: written,
        output: count(usage, "completion_tokens"),
        reasoning: usage["completion_tokens_details"]?.try(&.["reasoning_tokens"]?).try(&.as_i64?),
        tier: tier(service_tier, "default"),
      )
    end

    # From an Anthropic `usage` object, whose `input_tokens` leave out the
    # cache reads and writes. Writes go to the 5-minute cache unless the
    # `cache_creation` breakdown puts them in the 1-hour one.
    def self.from_anthropic(usage : JSON::Any?) : Usage?
      return unless usage && usage.as_h?
      written = count(usage, "cache_creation_input_tokens")
      written_1h = count(usage["cache_creation"]?, "ephemeral_1h_input_tokens")
      tools = usage["server_tool_use"]?
      new(
        input: count(usage, "input_tokens"),
        cache_read: count(usage, "cache_read_input_tokens"),
        cache_write: Math.max(0_i64, written - written_1h),
        cache_write_1h: written_1h,
        output: count(usage, "output_tokens"),
        reasoning: usage["output_tokens_details"]?.try(&.["thinking_tokens"]?).try(&.as_i64?),
        web_searches: count(tools, "web_search_requests"),
        code_executions: count(tools, "code_execution_requests"),
        tier: tier(usage["service_tier"]?.try(&.as_s?), "standard"),
        geo: usage["inference_geo"]?.try(&.as_s?),
      )
    end

    # From Gemini's `usageMetadata`, whose `promptTokenCount` includes the
    # cached tokens and whose `candidatesTokenCount` leaves out the
    # thoughts. Tool-use prompt tokens (fetched pages, search results)
    # bill as input.
    def self.from_gemini(meta : JSON::Any?) : Usage?
      return unless meta && meta.as_h?
      cached = count(meta, "cachedContentTokenCount")
      thoughts = meta["thoughtsTokenCount"]?.try(&.as_i64?)
      new(
        input: Math.max(0_i64, count(meta, "promptTokenCount") - cached) + count(meta, "toolUsePromptTokenCount"),
        cache_read: cached,
        output: count(meta, "candidatesTokenCount") + (thoughts || 0_i64),
        reasoning: thoughts,
        tier: tier(meta["serviceTier"]?.try(&.as_s?).try(&.downcase.lchop("service_tier_")), "standard", "unspecified"),
      )
    end

    private def self.count(obj : JSON::Any?, key : String) : Int64
      obj.try(&.as_h?).try(&.[key]?).try(&.as_i64?) || 0_i64
    end

    private def self.tier(value : String?, *standard : String) : String?
      return unless value
      standard.includes?(value) ? "standard" : value
    end
  end
end
