require "base64"

module Arcana::AI
  module Chat
    # An image in a chat message: a URL for the provider to fetch (https,
    # or a data URL), or the bytes themselves.
    #
    #   Message.user("What does this picture show?", images: [
    #     ImagePart.file("room.webp", detail: "low"),
    #     ImagePart.url("https://bucket.example/room.webp"),
    #   ])
    #
    # Providers take them differently: OpenAI gets a URL (bytes as a data
    # URL) and is the only one to use `detail`; Anthropic gets the bytes,
    # or fetches an https URL itself; Gemini needs the bytes and can't
    # fetch an https URL.
    struct ImagePart
      getter url : String?
      getter data : Bytes?
      getter media_type : String?
      getter detail : String? # OpenAI: "low", "high" or "auto"

      private def initialize(@url : String?, @data : Bytes?, @media_type : String?, @detail : String?)
      end

      def self.url(url : String, detail : String? = nil) : self
        new(url, nil, nil, detail)
      end

      def self.bytes(data : Bytes, media_type : String, detail : String? = nil) : self
        new(nil, data, media_type, detail)
      end

      # Read an image file; the media type comes from its extension.
      def self.file(path : String, detail : String? = nil) : self
        bytes(File.open(path, &.getb_to_end), Util.mime_for(path), detail)
      end

      # The image as a URL: the one given, or a data URL of the bytes.
      def to_url : String
        if u = @url
          u
        else
          "data:#{@media_type};base64,#{Base64.strict_encode(@data.not_nil!)}"
        end
      end

      # The image as {media_type, base64 data}: the bytes, or the payload
      # of a data URL. Nil for a URL the provider has to fetch.
      def inline : {String, String}?
        if d = @data
          {@media_type.not_nil!, Base64.strict_encode(d)}
        elsif (u = @url) && (m = u.match(/\Adata:([^;,]+);base64,(.*)\z/m))
          {m[1], m[2]}
        end
      end
    end
  end
end
