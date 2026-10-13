require "./spec_helper"
require "http/server"

# Answers every request with `body`, yielding the base URL.
private def serve(body : String, content_type = "application/json", &)
  server = HTTP::Server.new do |ctx|
    ctx.response.content_type = content_type
    ctx.response.print body
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

private def sse(*events : String) : String
  events.join("\n\n") + "\n\n"
end

# SSE data has to sit on one line.
private def flat(json : String) : String
  JSON.parse(json).to_json
end

private def ask
  Arcana::AI::Chat::Request.new(messages: [Arcana::AI::Chat::Message.user("hi")])
end

private def streamed(chat) : Arcana::AI::Chat::Response
  chat.stream(ask) { }
end

ANTHROPIC_USAGE = %({"input_tokens": 120, "cache_read_input_tokens": 3000,
  "cache_creation_input_tokens": 500,
  "cache_creation": {"ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 300},
  "output_tokens": 42, "output_tokens_details": {"thinking_tokens": 10},
  "server_tool_use": {"web_search_requests": 2, "web_fetch_requests": 1},
  "service_tier": "standard", "inference_geo": "us"})

OPENAI_USAGE = %({"prompt_tokens": 5000, "completion_tokens": 300, "total_tokens": 5300,
  "prompt_tokens_details": {"cached_tokens": 3000, "cache_write_tokens": 1000},
  "completion_tokens_details": {"reasoning_tokens": 100}})

GEMINI_USAGE = %({"promptTokenCount": 250000, "cachedContentTokenCount": 50000,
  "candidatesTokenCount": 800, "thoughtsTokenCount": 200, "toolUsePromptTokenCount": 40,
  "totalTokenCount": 251000})

describe Arcana::AI::Usage do
  describe "from Anthropic" do
    it "keeps cache reads and writes out of input and splits writes by duration" do
      u = Arcana::AI::Usage.from_anthropic(JSON.parse(ANTHROPIC_USAGE)).not_nil!
      u.input.should eq(120)
      u.cache_read.should eq(3000)
      u.cache_write.should eq(200)
      u.cache_write_1h.should eq(300)
      u.output.should eq(42)
      u.reasoning.should eq(10)
      u.web_searches.should eq(2)
      u.tier.should eq("standard")
      u.geo.should eq("us")
      u.prompt.should eq(3620)
    end

    it "counts writes as 5-minute ones without the breakdown" do
      u = Arcana::AI::Usage.from_anthropic(JSON.parse(%({"input_tokens": 5, "cache_creation_input_tokens": 70, "output_tokens": 1}))).not_nil!
      u.cache_write.should eq(70)
      u.cache_write_1h.should eq(0)
    end

    it "comes from a response" do
      body = %({"model": "claude-sonnet-5-5", "content": [{"type": "text", "text": "Hi"}],
        "stop_reason": "end_turn", "usage": #{ANTHROPIC_USAGE}})
      serve(body) do |url|
        r = Arcana::AI::Chat::Anthropic.new(api_key: "k", endpoint: "#{url}/v1/messages").complete(ask)
        r.usage.not_nil!.cache_write_1h.should eq(300)
        r.provider.should eq("anthropic")
      end
    end

    it "comes from a stream, merging message_start and message_delta" do
      start_usage = %({"input_tokens": 120, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 500,
        "cache_creation": {"ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 300},
        "output_tokens": 1, "service_tier": "standard", "inference_geo": "us"})
      body = sse(
        %(event: message_start\ndata: {"type": "message_start", "message": {"model": "claude-sonnet-5-5", "usage": #{flat(start_usage)}}}),
        %(event: content_block_delta\ndata: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hi"}}),
        %(event: message_delta\ndata: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 42, "input_tokens": null, "server_tool_use": {"web_search_requests": 2}}}),
        %(event: message_stop\ndata: {"type": "message_stop"}),
      )
      serve(body, "text/event-stream") do |url|
        u = streamed(Arcana::AI::Chat::Anthropic.new(api_key: "k", endpoint: "#{url}/v1/messages")).usage.not_nil!
        u.input.should eq(120)
        u.cache_read.should eq(3000)
        u.cache_write.should eq(200)
        u.cache_write_1h.should eq(300)
        u.output.should eq(42)
        u.web_searches.should eq(2)
        u.geo.should eq("us")
      end
    end

    it "is nil for a stream that reports none" do
      body = sse(
        %(event: message_start\ndata: {"type": "message_start", "message": {"model": "claude-sonnet-5-5"}}),
        %(event: content_block_delta\ndata: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hi"}}),
        %(event: message_stop\ndata: {"type": "message_stop"}),
      )
      serve(body, "text/event-stream") do |url|
        r = streamed(Arcana::AI::Chat::Anthropic.new(api_key: "k", endpoint: "#{url}/v1/messages"))
        r.usage.should be_nil
        r.cost.as(Arcana::AI::Pricing::Unpriced).reason.should eq(Arcana::AI::Pricing::Unpriced::Reason::NoUsage)
      end
    end
  end

  describe "from OpenAI" do
    it "takes cached tokens and cache writes out of input" do
      u = Arcana::AI::Usage.from_openai(JSON.parse(OPENAI_USAGE), "default").not_nil!
      u.input.should eq(1000)
      u.cache_read.should eq(3000)
      u.cache_write.should eq(1000)
      u.output.should eq(300)
      u.reasoning.should eq(100)
      u.tier.should eq("standard")
    end

    it "keeps other tiers by name" do
      Arcana::AI::Usage.from_openai(JSON.parse(OPENAI_USAGE), "flex").not_nil!.tier.should eq("flex")
    end

    it "comes from a response" do
      body = %({"model": "gpt-4o-mini-2024-07-18", "service_tier": "default",
        "choices": [{"message": {"content": "Hi"}, "finish_reason": "stop"}], "usage": #{OPENAI_USAGE}})
      serve(body) do |url|
        r = Arcana::AI::Chat::OpenAI.new(api_key: "k", endpoint: "#{url}/v1/chat/completions").complete(ask)
        r.usage.not_nil!.input.should eq(1000)
        r.provider.should eq("openai")
      end
    end

    it "comes from a stream, skipping the null usage on earlier chunks" do
      body = sse(
        %(data: {"model": "gpt-6-sol", "service_tier": "default", "choices": [{"index": 0, "delta": {"content": "Hi"}}], "usage": null}),
        %(data: {"model": "gpt-6-sol", "service_tier": "default", "choices": [], "usage": #{flat(OPENAI_USAGE)}}),
        "data: [DONE]",
      )
      serve(body, "text/event-stream") do |url|
        u = streamed(Arcana::AI::Chat::OpenAI.new(api_key: "k", endpoint: "#{url}/v1/chat/completions")).usage.not_nil!
        u.input.should eq(1000)
        u.cache_write.should eq(1000)
        u.tier.should eq("standard")
      end
    end

    it "is nil for a stream that reports none" do
      body = sse(%(data: {"model": "gpt-6-sol", "choices": [{"index": 0, "delta": {"content": "Hi"}}]}), "data: [DONE]")
      serve(body, "text/event-stream") do |url|
        streamed(Arcana::AI::Chat::OpenAI.new(api_key: "k", endpoint: "#{url}/v1/chat/completions")).usage.should be_nil
      end
    end

    it "carries the name of a compatible service" do
      chat = Arcana::AI::Registry.create_chat("grok", {"api_key" => JSON::Any.new("k")})
      chat.name.should eq("grok")
    end
  end

  describe "from Gemini" do
    it "takes cached tokens out of input and adds thoughts to output" do
      u = Arcana::AI::Usage.from_gemini(JSON.parse(GEMINI_USAGE)).not_nil!
      u.input.should eq(200_040)
      u.cache_read.should eq(50_000)
      u.output.should eq(1000)
      u.reasoning.should eq(200)
      u.tier.should be_nil
    end

    it "comes from a response" do
      body = %({"candidates": [{"content": {"parts": [{"text": "Hi"}]}, "finishReason": "STOP"}],
        "usageMetadata": #{GEMINI_USAGE}, "modelVersion": "gemini-2.5-pro"})
      serve(body) do |url|
        r = Arcana::AI::Chat::Gemini.new(api_key: "k", endpoint: "#{url}/v1beta").complete(ask)
        r.usage.not_nil!.output.should eq(1000)
        r.model.should eq("gemini-2.5-pro")
      end
    end

    it "comes from a stream, from the last totals, even in a chunk with no candidates" do
      body = sse(
        %(data: {"candidates": [{"content": {"parts": [{"text": "Hi"}]}}], "usageMetadata": {"promptTokenCount": 10}, "modelVersion": "gemini-2.5-pro"}),
        %(data: {"candidates": [{"content": {"parts": [{"text": "!"}]}, "finishReason": "STOP"}], "modelVersion": "gemini-2.5-pro"}),
        %(data: {"candidates": [], "usageMetadata": #{flat(GEMINI_USAGE)}, "modelVersion": "gemini-2.5-pro"}),
      )
      serve(body, "text/event-stream") do |url|
        r = streamed(Arcana::AI::Chat::Gemini.new(api_key: "k", model: "gemini-pro-latest", endpoint: "#{url}/v1beta"))
        r.model.should eq("gemini-2.5-pro")
        r.usage.not_nil!.cache_read.should eq(50_000)
      end
    end
  end

  describe "from embeddings" do
    it "is the tokens the provider reported" do
      body = %({"data": [{"index": 0, "embedding": [0.1, 0.2]}], "model": "text-embedding-3-small", "usage": {"prompt_tokens": 8, "total_tokens": 8}})
      serve(body) do |url|
        r = Arcana::AI::Embed::OpenAI.new(api_key: "k", endpoint: "#{url}/v1/embeddings").embed(Arcana::AI::Embed::Request.single("hi"))
        r.usage.not_nil!.input.should eq(8)
      end
    end

    it "is nil when the provider reported none" do
      body = %({"data": [{"index": 0, "embedding": [0.1, 0.2]}]})
      serve(body) do |url|
        r = Arcana::AI::Embed::Voyage.new(api_key: "k", endpoint: "#{url}/v1/embeddings").embed(Arcana::AI::Embed::Request.single("hi"))
        r.usage.should be_nil
        r.@total_tokens.should eq(0)
      end
    end
  end

  it "adds up, keeping a tier both share" do
    a = Arcana::AI::Usage.new(input: 5, output: 2, tier: "standard")
    b = Arcana::AI::Usage.new(input: 7, cache_read: 3, tier: "standard", reasoning: 1)
    sum = a + b
    {sum.input, sum.output, sum.cache_read, sum.reasoning, sum.tier}.should eq({12, 2, 3, 1, "standard"})
  end
end
