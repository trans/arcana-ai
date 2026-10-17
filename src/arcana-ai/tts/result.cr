module Arcana::AI
  module TTS
    struct Result
      property output_path : String
      property model : String
      property provider : String
      property raw_request : String   # JSON request body sent to API
      property status_code : Int32    # HTTP status
      property content_type : String  # response Content-Type
      property content_length : Int64 # response body size in bytes
      property audio : Bytes          # audio, set only by in-memory synthesize

      # What the call used, when the provider reports it (OpenAI's
      # gpt-4o-mini-tts in tokens, ElevenLabs in credits); nil when it
      # didn't. `cost` prices it.
      property usage : Usage?

      def initialize(
        @output_path : String,
        @model : String = "",
        @provider : String = "",
        @raw_request : String = "",
        @status_code : Int32 = 0,
        @content_type : String = "",
        @content_length : Int64 = 0,
        @audio : Bytes = Bytes.empty,
        @usage : Usage? = nil,
      )
      end

      # What this call cost; see `Pricing`. `at` is when it was made.
      def cost(at : Time = Time.utc, table : Pricing::Table = Pricing::Table.default) : Pricing::Cost | Pricing::Unpriced
        Pricing.cost(provider, model, usage, at, table)
      end
    end
  end
end
