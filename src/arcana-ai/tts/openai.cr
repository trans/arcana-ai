require "base64"
require "http/client"
require "json"

module Arcana::AI
  module TTS
    class OpenAI < Provider
      ENDPOINT      = "https://api.openai.com/v1/audio/speech"
      DEFAULT_MODEL = "gpt-4o-mini-tts"
      DEFAULT_VOICE = "alloy"

      # The Content-Type OpenAI sends with each audio format.
      MIME_TYPES = {"mp3" => "audio/mpeg", "opus" => "audio/opus", "aac" => "audio/aac",
                    "flac" => "audio/flac", "wav" => "audio/wav", "pcm" => "audio/pcm"}

      getter model : String

      def initialize(
        @api_key : String,
        @model : String = DEFAULT_MODEL,
        @voice : String = DEFAULT_VOICE,
        @endpoint : String = ENDPOINT,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for OpenAI TTS") if @api_key.strip.empty?
        @trace = trace
      end

      def name : String
        "openai"
      end

      def synthesize(request : Request) : Result
        model = request.model.empty? ? @model : request.model
        voice = request.voice.empty? ? @voice : request.voice
        payload = build_payload(request, model, voice)

        emit_request_trace(request, model, voice)

        response = post_api(payload)

        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "openai:tts")
        end

        if events?(model)
          audio = IO::Memory.new
          usage = read_events(IO::Memory.new(response.body), response.status_code) { |chunk| audio.write(chunk) }
          return Result.new("", model, "openai",
            raw_request: payload,
            status_code: response.status_code,
            content_type: MIME_TYPES[request.response_format]? || "",
            content_length: audio.size.to_i64,
            audio: audio.to_slice,
            usage: usage)
        end

        Result.new("", model, "openai",
          raw_request: payload,
          status_code: response.status_code,
          content_type: response.headers["Content-Type"]? || "",
          content_length: response.body.bytesize.to_i64,
          audio: response.body.to_slice)
      end

      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise CancelledError.new if ctx.try(&.cancelled?)

        model = request.model.empty? ? @model : request.model
        voice = request.voice.empty? ? @voice : request.voice
        payload = build_payload(request, model, voice)
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds

        if c = ctx
          spawn do
            until c.cancelled?
              sleep 100.milliseconds
            end
            client.close rescue nil
          end
        end

        total_bytes = 0_i64
        content_type = ""
        usage = nil

        begin
          client.post(uri.request_target, headers: headers, body: payload) do |response|
            unless response.success?
              body = response.body_io.gets_to_end
              raise APIError.new(response.status_code, body, "openai:tts:stream")
            end

            if events?(model)
              content_type = MIME_TYPES[request.response_format]? || ""
              usage = read_events(response.body_io, response.status_code) do |chunk|
                raise CancelledError.new if ctx.try(&.cancelled?)
                total_bytes += chunk.size
                block.call(chunk)
              end
              next
            end

            content_type = response.headers["Content-Type"]? || ""
            buf = Bytes.new(8192)

            while (bytes_read = response.body_io.read(buf)) > 0
              raise CancelledError.new if ctx.try(&.cancelled?)
              chunk = buf[0, bytes_read]
              total_bytes += bytes_read
              block.call(chunk)
            end
          end
        rescue ex : CancelledError
          raise ex
        rescue ex : IO::Error
          raise CancelledError.new if ctx.try(&.cancelled?)
          raise ex
        end

        Result.new("",
          model: model,
          provider: "openai",
          raw_request: payload,
          status_code: 200,
          content_type: content_type,
          content_length: total_bytes,
          usage: usage,
        )
      end

      # Does the model speak in events? Every model but tts-1 and tts-1-hd
      # can, and only then does OpenAI report the call's usage, at the end.
      private def events?(model : String) : Bool
        !model.starts_with?("tts-1")
      end

      # Reads the event stream, passing each piece of audio to the block,
      # and returns the usage its last event reports.
      private def read_events(io : IO, status : Int32, & : Bytes ->) : Usage?
        usage = nil
        while line = io.gets
          next unless line.starts_with?("data:")
          data = line.lchop("data:").strip
          next if data.empty? || data == "[DONE]"
          event = JSON.parse(data)
          case event["type"]?.try(&.as_s?)
          when "speech.audio.delta"
            yield Base64.decode(event["audio"].as_s)
          when "speech.audio.done"
            usage = Usage.from_openai_speech(event["usage"]?)
          when "error"
            raise APIError.new(status, data, "openai:tts")
          end
        end
        usage
      end

      private def build_payload(request : Request, model : String, voice : String) : String
        JSON.build do |json|
          json.object do
            json.field "model", model
            json.field "voice", voice
            json.field "input", request.text.strip + "\n\n"
            json.field "response_format", request.response_format
            if instructions = request.instructions
              json.field "instructions", instructions
            end
            if speed = request.speed
              json.field "speed", speed
            end
            json.field "stream_format", "sse" if events?(model)
          end
        end
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(@endpoint)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def emit_request_trace(request : Request, model : String, voice : String) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:           "api_request_tts",
          event_type:      "api_request",
          provider:        "openai",
          endpoint:        @endpoint,
          model:           model,
          voice:           voice,
          response_format: request.response_format,
          tags:            tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_tts",
          event_type:     "api_response",
          provider:       "openai",
          endpoint:       @endpoint,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })
      end
    end
  end
end
