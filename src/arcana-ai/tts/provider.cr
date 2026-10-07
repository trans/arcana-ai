module Arcana::AI
  module TTS
    VOICE_OPTIONS = %w(alloy ash ballad coral echo fable onyx nova sage shimmer verse)
    AUDIO_FORMATS = Set{"mp3", "wav", "aac", "flac", "opus", "pcm"}

    abstract class Provider
      include Arcana::AI::Traceable

      # Synthesize speech in memory. The audio is in `Result#audio`;
      # `Result#output_path` is empty.
      abstract def synthesize(request : Request) : Result
      abstract def name : String

      # Synthesize speech and write it to `output_path`. `Result#audio` is
      # left empty so callers that keep results don't also keep the audio.
      def synthesize(request : Request, output_path : String) : Result
        result = synthesize(request)
        File.write(output_path, result.audio)
        result.output_path = output_path
        result.audio = Bytes.empty
        result
      end

      # Stream audio chunks as they arrive. Override in subclasses.
      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise Error.new("Streaming not supported by #{name} TTS provider")
      end
    end
  end
end
