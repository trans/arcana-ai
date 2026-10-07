module Arcana::AI
  module TTS
    struct Request
      property text : String
      property voice : String            # empty = the provider's default voice
      property model : String            # empty = the provider's default model
      property response_format : String
      property instructions : String?    # style/persona instructions (OpenAI)
      property speed : Float64?          # 0.25-4.0
      property previous_text : String?   # preceding speech for prosody continuity (ElevenLabs)
      property next_text : String?       # following speech for prosody continuity (ElevenLabs)
      property trace_tags : Hash(String, String)?

      def initialize(
        @text : String,
        @voice : String = "",
        @model : String = "",
        @response_format : String = "opus",
        @instructions : String? = nil,
        @speed : Float64? = nil,
        @previous_text : String? = nil,
        @next_text : String? = nil,
        @trace_tags : Hash(String, String)? = nil,
      )
      end
    end
  end
end
