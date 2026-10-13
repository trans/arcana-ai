module Arcana::AI
  module Embed
    struct Result
      property embeddings : Array(Array(Float64))
      property token_counts : Array(Int32)

      # Deprecated: 0 when the provider reported no count, where `usage`
      # is nil. Goes away in arcana-ai 0.6.0.
      @total_tokens : Int32

      @[Deprecated("Use `usage.input` (nil `usage` means the provider reported none), and `cost` for what the call cost. Removed in arcana-ai 0.6.0.")]
      def total_tokens : Int32
        @total_tokens
      end

      @[Deprecated("Set `usage`. Removed in arcana-ai 0.6.0.")]
      def total_tokens=(@total_tokens : Int32)
      end

      # The tokens the provider billed, as a `Usage` (all `input`); nil
      # when it reported none. `Pricing` prices it.
      property usage : Usage?
      property model : String
      property provider : String
      property raw_request : String
      property raw_response : String

      # Retries `embed_with_retry` needed, and the time spent waiting.
      property retries : Int32 = 0
      property retry_wait : Time::Span = Time::Span.zero

      def initialize(
        @embeddings : Array(Array(Float64)),
        @token_counts : Array(Int32) = [] of Int32,
        @total_tokens : Int32 = 0,
        @model : String = "",
        @provider : String = "",
        @raw_request : String = "",
        @raw_response : String = "",
        @usage : Usage? = nil,
      )
      end

      # Convenience accessor for single-text embeddings.
      def embedding : Array(Float64)
        @embeddings.first
      end

      def dimensions : Int32
        @embeddings.first?.try(&.size) || 0
      end
    end
  end
end
