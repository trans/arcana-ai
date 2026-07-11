module Arcana::AI
  module TTS
    VOICE_OPTIONS = %w(alloy ash ballad coral echo fable onyx nova sage shimmer verse)
    AUDIO_FORMATS = Set{"mp3", "wav", "aac", "flac", "opus", "pcm"}

    abstract class Provider
      include Arcana::AI::Traceable

      abstract def synthesize(request : Request, output_path : String) : Result
      abstract def name : String

      # TODO(0.2.x): add `abstract def synthesize_bytes(request : Request) : Bytes`
      # so callers that just want the audio in memory don't need to round-trip
      # through disk. arcana 0.20.3's openai:tts `inline: true` currently
      # synthesizes to a temp file, reads it back, base64-encodes, and deletes
      # (see bin/arcana.cr in the arcana repo). Promote here when a second
      # caller wants inline or the temp-file cost shows up in profiling.

      # Stream audio chunks as they arrive. Override in subclasses.
      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise Error.new("Streaming not supported by #{name} TTS provider")
      end
    end
  end
end
