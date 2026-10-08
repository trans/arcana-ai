module Arcana::AI
  module Embed
    struct Result
      property embeddings : Array(Array(Float64))
      property token_counts : Array(Int32)
      property total_tokens : Int32
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
