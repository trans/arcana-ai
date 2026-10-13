require "../spec_helper"
require "base64"
require "http/server"

# Not valid UTF-8, so a String round-trip that mangled bytes would show.
TTS_AUDIO = Bytes[0xFF, 0xFB, 0x90, 0x00, 0x01, 0x80, 0xC3, 0x28]

# The audio as OpenAI's speech events: in two pieces, then the usage.
TTS_EVENTS = [
  %(data: {"type":"speech.audio.delta","audio":"#{Base64.strict_encode(TTS_AUDIO[0, 5])}"}),
  %(data: {"type":"speech.audio.delta","audio":"#{Base64.strict_encode(TTS_AUDIO[5..])}"}),
  %(data: {"type":"speech.audio.done","usage":{"input_tokens":3,"output_tokens":37,"total_tokens":40}}),
  "data: [DONE]",
].join("\r\n\r\n") + "\r\n\r\n"

# Yields the endpoint and the requests seen so far, as {path, body}.
# Answers with events when the request asks for them.
private def with_tts_server(status = 200, &)
  seen = [] of {String, String}
  server = HTTP::Server.new do |ctx|
    body = ctx.request.body.try(&.gets_to_end) || ""
    seen << {ctx.request.resource, body}
    ctx.response.status_code = status
    if body.includes?(%("stream_format":"sse"))
      ctx.response.content_type = "text/event-stream; charset=utf-8"
      ctx.response.print TTS_EVENTS
    else
      ctx.response.content_type = "audio/mpeg"
      ctx.response.write(TTS_AUDIO)
    end
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}", seen
  ensure
    server.close
  end
end

private def tts_providers(endpoint : String) : Array(Arcana::AI::TTS::Provider)
  [
    Arcana::AI::TTS::OpenAI.new(api_key: "sk-test", endpoint: endpoint),
    Arcana::AI::TTS::ElevenLabs.new(api_key: "xi-test", endpoint: endpoint),
  ] of Arcana::AI::TTS::Provider
end

describe Arcana::AI::TTS::Provider do
  it "synthesizes into memory without touching disk" do
    with_tts_server do |endpoint|
      tts_providers(endpoint).each do |tts|
        result = tts.synthesize(Arcana::AI::TTS::Request.new(text: "hello", response_format: "mp3"))
        result.audio.should eq(TTS_AUDIO)
        result.output_path.should eq("")
        result.provider.should eq(tts.name)
        result.content_type.should eq("audio/mpeg")
        result.content_length.should eq(TTS_AUDIO.size)
      end
    end
  end

  it "synthesizes to a file, leaving audio empty" do
    with_tts_server do |endpoint|
      tts_providers(endpoint).each do |tts|
        path = File.tempname("arcana-ai-tts-spec-", ".mp3")
        begin
          result = tts.synthesize(Arcana::AI::TTS::Request.new(text: "hello", response_format: "mp3"), path)
          File.open(path, &.getb_to_end).should eq(TTS_AUDIO)
          result.output_path.should eq(path)
          result.audio.empty?.should be_true
          result.content_length.should eq(TTS_AUDIO.size)
        ensure
          File.delete(path) if File.exists?(path)
        end
      end
    end
  end

  it "fills a blank voice and model with the provider's own defaults" do
    with_tts_server do |endpoint, seen|
      request = Arcana::AI::TTS::Request.new(text: "hello")

      Arcana::AI::TTS::OpenAI.new(api_key: "sk-test", endpoint: endpoint).synthesize(request)
      body = JSON.parse(seen.last[1])
      body["model"].should eq(Arcana::AI::TTS::OpenAI::DEFAULT_MODEL)
      body["voice"].should eq(Arcana::AI::TTS::OpenAI::DEFAULT_VOICE)

      Arcana::AI::TTS::ElevenLabs.new(api_key: "xi-test", endpoint: endpoint,
        model: "eleven_flash_v2_5", voice_id: "v123").synthesize(request)
      path, raw = seen.last
      path.should start_with("/v123?")
      JSON.parse(raw)["model_id"].should eq("eleven_flash_v2_5")
    end
  end

  describe "OpenAI" do
    it "asks for events, which report the usage, and prices it" do
      with_tts_server do |endpoint, seen|
        result = Arcana::AI::TTS::OpenAI.new(api_key: "sk-test", endpoint: endpoint).synthesize(Arcana::AI::TTS::Request.new(text: "hello"))
        JSON.parse(seen.last[1])["stream_format"].should eq("sse")
        result.audio.should eq(TTS_AUDIO)
        result.content_type.should eq("audio/opus")
        usage = result.usage.not_nil!
        {usage.input, usage.audio_output}.should eq({3, 37})
        # 3 × $0.60 + 37 × $12 per million
        result.cost.as(Arcana::AI::Pricing::Cost).total.should eq(BigDecimal.new("0.0004458"))
      end
    end

    it "streams the audio from the events, with the usage at the end" do
      with_tts_server do |endpoint|
        chunks = [] of Bytes
        result = Arcana::AI::TTS::OpenAI.new(api_key: "sk-test", endpoint: endpoint)
          .stream(Arcana::AI::TTS::Request.new(text: "hello", response_format: "mp3")) { |c| chunks << c.dup }
        chunks.size.should eq(2)
        chunks.sum(&.size).should eq(TTS_AUDIO.size)
        result.content_length.should eq(TTS_AUDIO.size)
        result.content_type.should eq("audio/mpeg")
        result.usage.not_nil!.audio_output.should eq(37)
      end
    end

    it "doesn't ask tts-1 for events, which it can't send; its calls go unpriced" do
      with_tts_server do |endpoint, seen|
        result = Arcana::AI::TTS::OpenAI.new(api_key: "sk-test", endpoint: endpoint, model: "tts-1-hd")
          .synthesize(Arcana::AI::TTS::Request.new(text: "hello"))
        JSON.parse(seen.last[1])["stream_format"]?.should be_nil
        result.audio.should eq(TTS_AUDIO)
        result.usage.should be_nil
        result.cost.as(Arcana::AI::Pricing::Unpriced).reason.should eq(Arcana::AI::Pricing::Unpriced::Reason::NoUsage)
      end
    end
  end

  it "raises APIError on a non-2xx response and writes no file" do
    with_tts_server(status: 400) do |endpoint|
      tts_providers(endpoint).each do |tts|
        path = File.tempname("arcana-ai-tts-spec-", ".mp3")
        expect_raises(Arcana::AI::APIError) do
          tts.synthesize(Arcana::AI::TTS::Request.new(text: "hello"), path)
        end
        File.exists?(path).should be_false
      end
    end
  end
end
