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

    it "omits reasoning fields when thinking is nil" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["reasoning_effort"]?.should be_nil
    end

    it "omits reasoning fields when thinking.enabled is false" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: false, effort: "high"),
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["reasoning_effort"]?.should be_nil
    end
  end

  describe "request building — max tokens" do
    request = Arcana::AI::Chat::Request.new(
      messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
      max_tokens: 150,
    )

    # gpt-5 on and the o-series reject `max_tokens`; every OpenAI model
    # takes `max_completion_tokens` (checked live 2026-10-13).
    it "sends max_completion_tokens to OpenAI, for any model" do
      provider = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test")
      {"gpt-4o-mini", "gpt-6-luna"}.each do |model|
        payload = JSON.parse(provider.test_build_payload(request, model))
        payload["max_completion_tokens"].as_i.should eq(150)
        payload["max_tokens"]?.should be_nil
      end
    end

    it "keeps max_tokens for a compatible service" do
      provider = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test", name: "deepseek")
      payload = JSON.parse(provider.test_build_payload(request, "deepseek-chat"))
      payload["max_tokens"].as_i.should eq(150)
      payload["max_completion_tokens"]?.should be_nil
    end

    it "sends max_completion_tokens to a compatible service when reasoning" do
      provider = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test", name: "grok")
      reasoning = Arcana::AI::Chat::Request.new(
        messages: request.messages,
        max_tokens: 150,
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true),
      )
      payload = JSON.parse(provider.test_build_payload(reasoning, "grok-3-mini"))
      payload["max_completion_tokens"].as_i.should eq(150)
      payload["max_tokens"]?.should be_nil
    end
  end

  describe "request building — temperature" do
    openai = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test")
    default = Arcana::AI::Chat::Request.new(
      messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
    )

    # Most models from gpt-5 on reject any temperature but their own.
    it "leaves the default out for OpenAI's newer models" do
      {"gpt-6-luna", "gpt-5-nano", "o4-mini"}.each do |model|
        JSON.parse(openai.test_build_payload(default, model))["temperature"]?.should be_nil
      end
    end

    it "sends the default to the GPT-4 and GPT-3.5 models" do
      {"gpt-4o-mini", "gpt-4.1-nano", "gpt-3.5-turbo", "ft:gpt-4o-mini-2024-07-18:acme::abc123"}.each do |model|
        JSON.parse(openai.test_build_payload(default, model))["temperature"].as_f.should eq(0.7)
      end
    end

    it "sends a temperature the caller picked" do
      request = Arcana::AI::Chat::Request.new(messages: default.messages, temperature: 0.2)
      JSON.parse(openai.test_build_payload(request, "gpt-6-luna"))["temperature"].as_f.should eq(0.2)
    end

    it "sends the default to a compatible service" do
      deepseek = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test", name: "deepseek")
      JSON.parse(deepseek.test_build_payload(default, "deepseek-chat"))["temperature"].as_f.should eq(0.7)
    end
  end
end
