module Arcana::AI
  module Chat
    abstract class Provider
      include Arcana::AI::Traceable

      abstract def complete(request : Request) : Response
      abstract def name : String

      # How failed calls are retried (see `RetryPolicy`). Set
      # `RetryPolicy.none` to raise the first failure instead.
      property retry_policy : RetryPolicy = RetryPolicy.new

      # Complete with cancellation support. Override for real mid-flight abort.
      def complete(request : Request, ctx : Context) : Response
        raise CancelledError.new if ctx.cancelled?
        complete(request)
      end

      # Stream a chat completion, yielding events as they arrive.
      # Override in subclasses that support streaming.
      def stream(request : Request, ctx : Context? = nil, &block : StreamEvent ->) : Response
        raise Error.new("Streaming not supported by #{name} provider")
      end

      # A `RetryPolicy#run` hook that traces each retry.
      protected def retry_tracer(request : Request) : Proc(Int32, Time::Span, String, Nil)
        tags = (request.trace_tags || {} of String => String).to_json
        provider = name
        ->(attempt : Int32, delay : Time::Span, reason : String) do
          emit_trace({
            phase:      "api_retry",
            event_type: "api_retry",
            provider:   provider,
            attempt:    attempt,
            delay_ms:   delay.total_milliseconds.round.to_i64,
            reason:     reason,
            tags:       tags,
          })
          nil
        end
      end

      # List available models. Override in subclasses that support it.
      def models : Array(String)
        [] of String
      end
    end
  end
end
