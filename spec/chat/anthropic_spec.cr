require "../spec_helper"

# Expose private helpers for testing without API calls.
class Arcana::AI::Chat::Anthropic
  def test_parse_response(body : String, payload : String = "{}") : Arcana::AI::Chat::Response
    parse_response(body, payload)
  end

  def test_build_payload(request : Arcana::AI::Chat::Request, model : String = "claude-sonnet-4-20250514", max_tokens : Int32 = 4096) : String
    build_payload(request, model, max_tokens)
  end
end

describe Arcana::AI::Chat::Anthropic do
  describe "registry" do
    it "is registered as a chat provider" do
      Arcana::AI::Registry.chat_providers.should contain("anthropic")
    end
  end

  describe "initialization" do
    it "raises on empty API key" do
      expect_raises(Arcana::AI::ConfigError, /API key/) do
        Arcana::AI::Chat::Anthropic.new(api_key: "")
      end
    end

    it "uses default model" do
      provider = Arcana::AI::Chat::Anthropic.new(api_key: "sk-test")
      provider.model.should eq(Arcana::AI::Chat::Anthropic::DEFAULT_MODEL)
      provider.name.should eq("anthropic")
    end
  end

  describe "response parsing" do
    provider = Arcana::AI::Chat::Anthropic.new(api_key: "sk-test")

    it "parses a simple text response" do
      body = %({
        "id": "msg_123",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [{"type": "text", "text": "Hello!"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 10, "output_tokens": 5}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Hello!")
      resp.finish_reason.should eq("stop")
      resp.model.should eq("claude-sonnet-4-20250514")
      resp.provider.should eq("anthropic")
      resp.prompt_tokens.should eq(10)
      resp.completion_tokens.should eq(5)
      resp.has_tool_calls?.should be_false
    end

    it "parses tool use response" do
      body = %({
        "id": "msg_456",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [
          {"type": "text", "text": "Let me check."},
          {"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": {"city": "Tokyo"}}
        ],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 20, "output_tokens": 15}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Let me check.")
      resp.finish_reason.should eq("tool_calls")
      resp.has_tool_calls?.should be_true
      resp.tool_calls.size.should eq(1)

      tc = resp.tool_calls[0]
      tc.id.should eq("toolu_1")
      tc.function.name.should eq("get_weather")
      tc.parsed_arguments["city"].as_s.should eq("Tokyo")
    end

    it "maps stop_reason to OpenAI-compatible finish_reason" do
      {"end_turn" => "stop", "tool_use" => "tool_calls", "max_tokens" => "length"}.each do |anthropic, expected|
        body = %({
          "content": [{"type": "text", "text": "x"}],
          "stop_reason": "#{anthropic}",
          "model": "test"
        })
        resp = provider.test_parse_response(body)
        resp.finish_reason.should eq(expected)
      end
    end

    it "extracts prompt caching tokens" do
      body = %({
        "id": "msg_789",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [{"type": "text", "text": "Cached!"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 80, "cache_creation_input_tokens": 15}
      })

      resp = provider.test_parse_response(body)
      resp.prompt_tokens.should eq(100)
      resp.completion_tokens.should eq(20)
      resp.cache_read_tokens.should eq(80)
      resp.cache_creation_tokens.should eq(15)
    end

    it "handles missing cache tokens gracefully" do
      body = %({
        "content": [{"type": "text", "text": "No cache"}],
        "stop_reason": "end_turn",
        "model": "test",
        "usage": {"input_tokens": 10, "output_tokens": 5}
      })

      resp = provider.test_parse_response(body)
      resp.cache_read_tokens.should be_nil
      resp.cache_creation_tokens.should be_nil
    end

    it "captures server tool results" do
      body = %({
        "id": "msg_st",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [
          {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "Crystal lang"}},
          {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [{"type": "web_search_result", "url": "https://crystal-lang.org", "title": "Crystal"}]},
          {"type": "text", "text": "Crystal is a compiled language."}
        ],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 50, "output_tokens": 30}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Crystal is a compiled language.")
      resp.server_tool_results.size.should eq(2)
      resp.server_tool_results[0]["type"].as_s.should eq("server_tool_use")
      resp.server_tool_results[1]["type"].as_s.should eq("web_search_tool_result")
    end

    it "returns empty server_tool_results when none present" do
      body = %({
        "content": [{"type": "text", "text": "hi"}],
        "stop_reason": "end_turn",
        "model": "test",
        "usage": {"input_tokens": 5, "output_tokens": 3}
      })

      resp = provider.test_parse_response(body)
      resp.server_tool_results.should be_empty
    end

    it "stores raw request and response" do
      body = %({"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn", "model": "test"})
      resp = provider.test_parse_response(body, "the-request")
      resp.raw_request.should eq("the-request")
      resp.raw_json.should eq(body)
    end

    it "extracts thinking blocks into thinking_content" do
      body = %({
        "content": [
          {"type": "thinking", "thinking": "Let me work through this..."},
          {"type": "thinking", "thinking": "Actually, the answer is 42."},
          {"type": "text", "text": "The answer is 42."}
        ],
        "stop_reason": "end_turn",
        "model": "claude-opus-4",
        "usage": {"input_tokens": 20, "output_tokens": 15}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("The answer is 42.")
      resp.thinking_content.should eq("Let me work through this...\n\nActually, the answer is 42.")
    end

    it "marks redacted thinking without losing the signal" do
      body = %({
        "content": [
          {"type": "redacted_thinking", "data": "..."},
          {"type": "text", "text": "OK."}
        ],
        "stop_reason": "end_turn",
        "model": "claude-opus-4"
      })

      resp = provider.test_parse_response(body)
      resp.thinking_content.should eq("[redacted]")
    end
  end

  describe "request building — extended thinking" do
    provider = Arcana::AI::Chat::Anthropic.new(api_key: "sk-test")

    it "emits `thinking` block when Request.thinking is enabled" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true, budget: 2048),
      )
      payload = JSON.parse(provider.test_build_payload(request, max_tokens: 4096))
      payload["thinking"]["type"].as_s.should eq("enabled")
      payload["thinking"]["budget_tokens"].as_i.should eq(2048)
    end

    it "defaults budget to 1024 when caller didn't specify" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true),
      )
      payload = JSON.parse(provider.test_build_payload(request, max_tokens: 4096))
      payload["thinking"]["budget_tokens"].as_i.should eq(1024)
    end

    it "clamps budget below max_tokens (Anthropic requires budget < max_tokens)" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
        thinking: Arcana::AI::Chat::ThinkingConfig.new(enabled: true, budget: 10000),
      )
      payload = JSON.parse(provider.test_build_payload(request, max_tokens: 4096))
      payload["thinking"]["budget_tokens"].as_i.should eq(4095)
    end

    it "omits `thinking` when Request.thinking is nil" do
      request = Arcana::AI::Chat::Request.new(
        messages: [Arcana::AI::Chat::Message.new(role: "user", content: "hi")],
      )
      payload = JSON.parse(provider.test_build_payload(request))
      payload["thinking"]?.should be_nil
    end
  end
end
