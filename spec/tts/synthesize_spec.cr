require "../spec_helper"
require "http/server"

# Not valid UTF-8, so a String round-trip that mangled bytes would show.
TTS_AUDIO = Bytes[0xFF, 0xFB, 0x90, 0x00, 0x01, 0x80, 0xC3, 0x28]

# Yields the endpoint and the requests seen so far, as {path, body}.
private def with_tts_server(status = 200, &)
  seen = [] of {String, String}
  server = HTTP::Server.new do |ctx|
    seen << {ctx.request.resource, ctx.request.body.try(&.gets_to_end) || ""}
    ctx.response.status_code = status
    ctx.response.content_type = "audio/mpeg"
    ctx.response.write(TTS_AUDIO)
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
        result = tts.synthesize(Arcana::AI::TTS::Request.new(text: "hello"))
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
          result = tts.synthesize(Arcana::AI::TTS::Request.new(text: "hello"), path)
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
