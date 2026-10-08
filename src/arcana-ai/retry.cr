require "http/client"
require "json"
require "socket"

module Arcana::AI
  class APIError
    # How long the provider asked us to wait before trying again, from
    # `Retry-After` / `retry-after-ms` or a retry delay in the body.
    getter retry_after : Time::Span? = nil

    def initialize(@status_code : Int32, @response_body : String, provider : String, @retry_after : Time::Span?)
      super("#{provider} API error (#{@status_code}): #{@response_body}")
    end

    # Build from a failed HTTP response, keeping the retry hint.
    def self.from(response : HTTP::Client::Response, body : String, provider : String) : self
      new(response.status_code, body, provider, RetryPolicy.retry_after(response.headers, body))
    end
  end

  # How often one call was retried, and how long it waited in all.
  record RetryStats, retries : Int32 = 0, waited : Time::Span = Time::Span.zero

  # Retrying calls that failed for a reason that may pass: rate limits
  # (429), server errors (500, 502, 503, 504, and Anthropic's 529
  # overloaded) and network errors.
  #
  # - Waits as long as the provider asks (`Retry-After`, `retry-after-ms`,
  #   or Gemini's `retryDelay`), up to `max_wait`; a longer requested
  #   wait fails at once rather than stalling the caller.
  # - Otherwise backs off `base_delay`, doubling each time, capped at
  #   `max_delay`, with ±25% jitter so many clients don't retry in step.
  # - Never retries what can't pass soon: OpenAI's `insufficient_quota`
  #   (a spending cap, sent as 429) or a per-day quota.
  # - A network error is retried only before the response has started
  #   (see `Attempt#started!`): a stream that already sent events to the
  #   caller can't be replayed.
  struct RetryPolicy
    RETRY_STATUSES = {429, 500, 502, 503, 504, 529} # 529: Anthropic overloaded

    getter max_retries : Int32
    getter base_delay : Time::Span
    getter max_delay : Time::Span
    getter max_wait : Time::Span

    def initialize(@max_retries : Int32 = 3, @base_delay : Time::Span = 500.milliseconds,
                   @max_delay : Time::Span = 8.seconds, @max_wait : Time::Span = 30.seconds)
    end

    # No retries: the first failure is raised.
    def self.none : self
      new(max_retries: 0)
    end

    # One try at the call. A streaming call marks the point after which
    # it can't be retried.
    class Attempt
      getter? started = false

      def started! : Nil
        @started = true
      end
    end

    # Run the block (one try per call) until it returns, fails for good,
    # or `ctx` is cancelled. `on_retry` hears of each retry before the
    # wait: (retry number, delay, reason).
    def run(ctx : Context? = nil, on_retry : Proc(Int32, Time::Span, String, Nil)? = nil,
            & : Attempt -> T) : {T, RetryStats} forall T
      retries = 0
      waited = Time::Span.zero
      loop do
        attempt = Attempt.new
        begin
          return {yield(attempt), RetryStats.new(retries, waited)}
        rescue ex : CancelledError
          raise ex
        rescue ex
          raise ex if ctx.try(&.cancelled?)
          delay = delay_for(ex, retries, attempt)
          raise ex unless delay
          retries += 1
          on_retry.try &.call(retries, delay, reason(ex))
          pause(delay, ctx)
          waited += delay
        end
      end
    end

    # The wait before retrying after `ex`, or nil to give up.
    def delay_for(ex : Exception, retries : Int32, attempt : Attempt = Attempt.new) : Time::Span?
      return nil if retries >= @max_retries
      case ex
      when APIError
        return nil unless RETRY_STATUSES.includes?(ex.status_code)
        return nil if permanent?(ex.response_body)
        if asked = ex.retry_after
          return asked <= @max_wait ? asked : nil
        end
        backoff(retries)
      when IO::TimeoutError
        # A connect timeout is worth another try; a read timeout means
        # the provider may already be working (and billing) on it.
        ex.message.to_s.downcase.includes?("connect") ? backoff(retries) : nil
      when IO::Error
        attempt.started? ? nil : backoff(retries)
      else
        nil
      end
    end

    def backoff(retries : Int32) : Time::Span
      step = @base_delay * (2 ** retries)
      step = @max_delay if step > @max_delay
      step * (0.75 + Random.rand * 0.5)
    end

    private def permanent?(body : String) : Bool
      body.includes?("insufficient_quota") || body.includes?("PerDay")
    end

    private def reason(ex : Exception) : String
      ex.is_a?(APIError) ? "status #{ex.status_code}" : "#{ex.class.name}: #{ex.message}"
    end

    private def pause(delay : Time::Span, ctx : Context?) : Nil
      unless c = ctx
        sleep delay
        return
      end
      deadline = Time.instant + delay
      while (left = deadline - Time.instant) > Time::Span.zero
        raise CancelledError.new if c.cancelled?
        sleep({left, 50.milliseconds}.min)
      end
      raise CancelledError.new if c.cancelled?
    end

    # The wait a failed response asks for, if it names one.
    def self.retry_after(headers : HTTP::Headers, body : String) : Time::Span?
      if ms = headers["retry-after-ms"]?.try(&.strip.to_f?)
        return ms.milliseconds
      end
      if value = headers["retry-after"]?
        if seconds = value.strip.to_f?
          return seconds.seconds
        end
        if at = HTTP.parse_time(value)
          wait = at - Time.utc
          return wait > Time::Span.zero ? wait : Time::Span.zero
        end
      end
      gemini_retry_delay(body)
    end

    # Gemini puts it in the body: error.details[].retryDelay, e.g. "37s".
    private def self.gemini_retry_delay(body : String) : Time::Span?
      return nil unless body.includes?("retryDelay")
      details = JSON.parse(body)["error"]?.try(&.["details"]?).try(&.as_a?) || return nil
      details.each do |d|
        if (delay = d["retryDelay"]?.try(&.as_s?)) && (m = delay.match(/\A(\d+(?:\.\d+)?)s\z/))
          return m[1].to_f.seconds
        end
      end
      nil
    rescue JSON::ParseException
      nil
    end
  end
end
