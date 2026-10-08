require "../spec_helper"
require "http/server"

private PNG = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

# Answers every request with `reply`, yielding the base URL and the
# request bodies seen so far.
private def capture(reply : String, &)
  bodies = [] of JSON::Any
  server = HTTP::Server.new do |ctx|
    bodies << JSON.parse(ctx.request.body.try(&.gets_to_end) || "{}")
    ctx.response.content_type = "application/json"
    ctx.response.print reply
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}", bodies
  ensure
    server.close
  end
end

private def look(images)
  Arcana::AI::Chat::Request.new(messages: [Arcana::AI::Chat::Message.user("What does this show?", images: images)])
end

describe Arcana::AI::Chat::ImagePart do
  it "gives bytes as a data URL and a data URL as inline data" do
    part = Arcana::AI::Chat::ImagePart.bytes(PNG, "image/png")
    part.to_url.should eq("data:image/png;base64,#{Base64.strict_encode(PNG)}")
    part.inline.should eq({"image/png", Base64.strict_encode(PNG)})
    Arcana::AI::Chat::ImagePart.url(part.to_url).inline.should eq(part.inline)
    Arcana::AI::Chat::ImagePart.url("https://x.example/a.png").inline.should be_nil
  end

  it "reads a file, taking the media type from its extension" do
    path = File.tempname("room", ".webp")
    File.write(path, PNG)
    begin
      part = Arcana::AI::Chat::ImagePart.file(path, detail: "low")
      part.media_type.should eq("image/webp")
      part.data.should eq(PNG)
      part.detail.should eq("low")
    ensure
      File.delete(path)
    end
  end
end

describe "image input per provider" do
  it "OpenAI: text part, then image_url parts with detail" do
    msg = Arcana::AI::Chat::Message.user("What does this show?", images: [
      Arcana::AI::Chat::ImagePart.bytes(PNG, "image/png", detail: "low"),
      Arcana::AI::Chat::ImagePart.url("https://bucket.example/room.webp"),
    ])
    content = JSON.parse(msg.to_json)["content"].as_a
    content[0].should eq(JSON.parse(%({"type":"text","text":"What does this show?"})))
    content[1]["image_url"]["url"].as_s.should start_with("data:image/png;base64,")
    content[1]["image_url"]["detail"].should eq("low")
    content[2]["image_url"].should eq(JSON.parse(%({"url":"https://bucket.example/room.webp"})))
  end

  it "OpenAI: text-only messages are unchanged" do
    JSON.parse(Arcana::AI::Chat::Message.user("hello").to_json).should eq(JSON.parse(%({"role":"user","content":"hello"})))
    JSON.parse(Arcana::AI::Chat::Message.user("hello", images: [] of Arcana::AI::Chat::ImagePart).to_json)["content"].should eq("hello")
  end

  it "Anthropic: image blocks (base64 or url) before the text" do
    ok = %({"model":"c","content":[{"type":"text","text":"a room"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}})
    capture(ok) do |url, bodies|
      chat = Arcana::AI::Chat::Anthropic.new(api_key: "k", endpoint: "#{url}/v1/messages")
      chat.complete(look([Arcana::AI::Chat::ImagePart.bytes(PNG, "image/png", detail: "low"),
                          Arcana::AI::Chat::ImagePart.url("https://bucket.example/room.webp")]))
      blocks = bodies.last["messages"][0]["content"].as_a
      blocks[0].should eq(JSON.parse(%({"type":"image","source":{"type":"base64","media_type":"image/png","data":"#{Base64.strict_encode(PNG)}"}})))
      blocks[1].should eq(JSON.parse(%({"type":"image","source":{"type":"url","url":"https://bucket.example/room.webp"}})))
      blocks[2].should eq(JSON.parse(%({"type":"text","text":"What does this show?"})))
    end
  end

  it "Gemini: inlineData parts, and a clear error for a URL it can't fetch" do
    ok = %({"candidates":[{"content":{"parts":[{"text":"a room"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}})
    capture(ok) do |url, bodies|
      chat = Arcana::AI::Chat::Gemini.new(api_key: "k", endpoint: "#{url}/v1beta")
      chat.complete(look([Arcana::AI::Chat::ImagePart.bytes(PNG, "image/png")]))
      parts = bodies.last["contents"][0]["parts"].as_a
      parts[0].should eq(JSON.parse(%({"inlineData":{"mimeType":"image/png","data":"#{Base64.strict_encode(PNG)}"}})))
      parts[1].should eq(JSON.parse(%({"text":"What does this show?"})))

      expect_raises(Arcana::AI::ConfigError, /can't fetch image URLs/) do
        chat.complete(look([Arcana::AI::Chat::ImagePart.url("https://bucket.example/room.webp")]))
      end
      bodies.size.should eq(1)
    end
  end
end
