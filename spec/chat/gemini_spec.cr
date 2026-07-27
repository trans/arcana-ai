require "../spec_helper"

# Expose private helpers for testing without API calls.
class Arcana::AI::Chat::Gemini
  def test_parse_response(body : String, payload : String = "{}") : Arcana::AI::Chat::Response
    parse_response(body, payload)
  end

  def test_build_payload(request : Arcana::AI::Chat::Request, model : String = "gemini-2.5-pro") : String
    build_payload(request, model)
  end
end

describe Arcana::AI::Chat::Gemini do
  describe "registry" do
    it "is registered as a chat provider" do
      Arcana::AI::Registry.chat_providers.should contain("gemini")
    end
  end

  describe "initialization" do
    it "raises on empty API key" do
      expect_raises(Arcana::AI::ConfigError, /API key/) do
        Arcana::AI::Chat::Gemini.new(api_key: "")
      end
    end

    it "uses default model" do
      provider = Arcana::AI::Chat::Gemini.new(api_key: "test-key")
      provider.model.should eq(Arcana::AI::Chat::Gemini::DEFAULT_MODEL)
      provider.name.should eq("gemini")
    end
  end

  describe "response parsing" do
    provider = Arcana::AI::Chat::Gemini.new(api_key: "test-key")

    it "parses a simple text response" do
      body = %({
        "candidates": [{
          "content": {
            "parts": [{"text": "Hello!"}],
            "role": "model"
          },
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 10,
          "candidatesTokenCount": 5,
          "totalTokenCount": 15
        },
        "modelVersion": "gemini-2.5-flash"
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Hello!")
      resp.finish_reason.should eq("stop")
      resp.model.should eq("gemini-2.5-flash")
      resp.provider.should eq("gemini")
      resp.prompt_tokens.should eq(10)
      resp.completion_tokens.should eq(5)
      resp.has_tool_calls?.should be_false
    end

    it "parses function call response" do
      body = %({
        "candidates": [{
          "content": {
            "parts": [
              {"text": "Let me check the weather."},
              {"functionCall": {"name": "get_weather", "args": {"city": "Tokyo"}}}
            ],
            "role": "model"
          },
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 20,
          "candidatesTokenCount": 15,
          "totalTokenCount": 35
        },
        "modelVersion": "gemini-2.5-flash"
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Let me check the weather.")
      resp.has_tool_calls?.should be_true
      resp.tool_calls.size.should eq(1)

      tc = resp.tool_calls[0]
      tc.function.name.should eq("get_weather")
      tc.parsed_arguments["city"].as_s.should eq("Tokyo")
    end

    it "maps finishReason to normalized finish_reason" do
      {"STOP" => "stop", "MAX_TOKENS" => "length", "SAFETY" => "safety"}.each do |gemini, expected|
        body = %({
          "candidates": [{
            "content": {"parts": [{"text": "x"}], "role": "model"},
            "finishReason": "#{gemini}"
          }],
          "modelVersion": "test"
        })
        resp = provider.test_parse_response(body)
        resp.finish_reason.should eq(expected)
      end
    end

    it "handles missing usage metadata" do
      body = %({
        "candidates": [{
          "content": {"parts": [{"text": "hi"}], "role": "model"},
          "finishReason": "STOP"
        }],
        "modelVersion": "test"
      })

      resp = provider.test_parse_response(body)
      resp.prompt_tokens.should be_nil
      resp.completion_tokens.should be_nil
    end

    it "stores raw request and response" do
      body = %({
        "candidates": [{
          "content": {"parts": [{"text": "hi"}], "role": "model"},
          "finishReason": "STOP"
        }],
        "modelVersion": "test"
      })
      resp = provider.test_parse_response(body, "the-request")
      resp.raw_request.should eq("the-request")
      resp.raw_json.should eq(body)
    end

    it "separates thought parts into thinking_content" do
      body = %({
        "candidates": [{
          "content": {"parts": [
            {"thought": true, "text": "Let me think about this..."},
            {"thought": true, "text": "The user wants a joke."},
            {"text": "Why did the chicken cross the road?"}
          ]},
          "finishReason": "STOP"
        }],
        "modelVersion": "gemini-2.5-pro",
        "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 15, "thoughtsTokenCount": 42}
      })
      resp = provider.test_parse_response(body)
      resp.content.should eq("Why did the chicken cross the road?")
      resp.thinking_content.should eq("Let me think about this...\n\nThe user wants a joke.")
      resp.reasoning_tokens.should eq(42)
    end
  end

  describe "request building — thinkingConfig" do
    provider = Arcana::AI::Chat::Gemini.new(api_key: "test-key")

    it "emits generationConfig.thinkingConfig when Request.thinking is enabled" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true, budget: 4096),
      )
      payload = JSON.parse(provider.test_build_payload(request))
      cfg = payload["generationConfig"]["thinkingConfig"]
      cfg["thinkingBudget"].as_i.should eq(4096)
      cfg["includeThoughts"].as_bool.should be_true
    end

    it "honors include_thoughts: false" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true, include_thoughts: false),
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["generationConfig"]["thinkingConfig"]["includeThoughts"].as_bool.should be_false
    end

    it "omits thinkingBudget when caller didn't set it (model uses its own default)" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true),
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["generationConfig"]["thinkingConfig"]["thinkingBudget"]?.should be_nil
    end

    it "omits thinkingConfig entirely when Request.thinking is nil" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["generationConfig"]["thinkingConfig"]?.should be_nil
    end
  end
end
