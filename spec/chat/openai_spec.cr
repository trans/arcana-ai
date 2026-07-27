require "../spec_helper"

# Expose private helpers for testing without API calls.
class Arcana::AI::Chat::OpenAI
  def test_build_payload(request : Arcana::AI::Chat::Request, model : String = "gpt-4o-mini") : String
    build_payload(request, model)
  end
end

describe Arcana::AI::Chat::OpenAI do
  describe "registry" do
    it "is registered as a chat provider" do
      Arcana::AI::Registry.chat_providers.should contain("openai")
    end
  end

  describe "request building — reasoning_effort" do
    provider = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test")

    it "emits reasoning_effort + max_completion_tokens when thinking is enabled" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "solve x^2 = 4")],
        max_tokens: 2048,
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true, effort: "high"),
      )
      payload = JSON.parse(provider.test_build_payload(request, model: "o3-mini"))
      payload["reasoning_effort"].as_s.should eq("high")
      payload["max_completion_tokens"].as_i.should eq(2048)
      # Reasoning-mode payloads switch to max_completion_tokens; the old key
      # must not appear or the API rejects the request.
      payload["max_tokens"]?.should be_nil
    end

    it "defaults effort to \"medium\" when caller enabled thinking without picking a tier" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true),
      )
      payload = JSON.parse(provider.test_build_payload(request, model: "o3-mini"))
      payload["reasoning_effort"].as_s.should eq("medium")
    end

    it "omits reasoning fields + keeps classic max_tokens when thinking is nil" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        max_tokens: 150,
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["reasoning_effort"]?.should be_nil
      payload["max_completion_tokens"]?.should be_nil
      payload["max_tokens"].as_i.should eq(150)
    end

    it "omits reasoning fields when thinking.enabled is false" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: false, effort: "high"),
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["reasoning_effort"]?.should be_nil
      payload["max_completion_tokens"]?.should be_nil
    end
  end
end
