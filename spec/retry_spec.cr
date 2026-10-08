require "./spec_helper"
require "http/server"

private record Reply, status : Int32, body : String, headers : Hash(String, String) = {} of String => String,
  content_type : String = "application/json"

# Serves `replies` in order (repeating the last), yielding the base URL
# and the paths requested so far.
private def with_replies(replies : Array(Reply), &)
  queue = replies.dup
  seen = [] of String
  server = HTTP::Server.new do |ctx|
    ctx.request.body.try(&.gets_to_end)
    seen << ctx.request.path
    reply = queue.size > 1 ? queue.shift : queue.first
    ctx.response.status_code = reply.status
    ctx.response.content_type = reply.content_type
    reply.headers.each { |k, v| ctx.response.headers[k] = v }
    ctx.response.print reply.body
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}", seen
  ensure
    server.close
  end
end

private FAST = Arcana::AI::RetryPolicy.new(base_delay: 1.millisecond)

private OPENAI_OK    = %({"model":"gpt-x","choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}})
private ANTHROPIC_OK = %({"model":"claude-x","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}})
private GEMINI_OK    = %({"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}})

private def chat_request
  Arcana::AI::Chat::Request.new(messages: [Arcana::AI::Chat::Message.user("hello")])
end

private def api_error(status : Int32, body = "{}", retry_after : Time::Span? = nil)
  Arcana::AI::APIError.new(status, body, "test", retry_after)
end

describe Arcana::AI::RetryPolicy do
  describe ".retry_after" do
    it "reads retry-after-ms, retry-after seconds and dates, and Gemini's retryDelay" do
      rp = Arcana::AI::RetryPolicy
      rp.retry_after(HTTP::Headers{"retry-after-ms" => "250"}, "").should eq(250.milliseconds)
      rp.retry_after(HTTP::Headers{"Retry-After" => "2"}, "").should eq(2.seconds)
      dated = rp.retry_after(HTTP::Headers{"Retry-After" => HTTP.format_time(Time.utc + 10.seconds)}, "").not_nil!
      dated.should be_close(10.seconds, 1.5.seconds)
      gemini = %({"error":{"code":429,"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]}})
      rp.retry_after(HTTP::Headers.new, gemini).should eq(7.seconds)
      rp.retry_after(HTTP::Headers.new, "{}").should be_nil
    end
  end

  describe "#delay_for" do
    policy = Arcana::AI::RetryPolicy.new

    it "backs off for retryable statuses, with jitter around the step" do
      {429, 500, 502, 503, 504, 529}.each do |status|
        delay = policy.delay_for(api_error(status), 0).not_nil!
        delay.should be >= 375.milliseconds
        delay.should be <= 625.milliseconds
      end
      policy.delay_for(api_error(503), 2).not_nil!.should be >= 1500.milliseconds
    end

    it "waits as asked, but not longer than max_wait" do
      policy.delay_for(api_error(429, retry_after: 3.seconds), 0).should eq(3.seconds)
      policy.delay_for(api_error(429, retry_after: 60.seconds), 0).should be_nil
    end

    it "gives up on what won't pass: other statuses, spending caps, daily quotas, used-up retries" do
      policy.delay_for(api_error(400), 0).should be_nil
      policy.delay_for(api_error(429, %({"error":{"code":"insufficient_quota"}})), 0).should be_nil
      policy.delay_for(api_error(429, %({"quotaId":"GenerateRequestsPerDayPerProjectPerModel"})), 0).should be_nil
      policy.delay_for(api_error(503), 3).should be_nil
    end

    it "retries network errors only before the response starts, and connect timeouts but not read timeouts" do
      policy.delay_for(IO::Error.new("Connection reset"), 0).should_not be_nil
      started = Arcana::AI::RetryPolicy::Attempt.new
      started.started!
      policy.delay_for(IO::Error.new("Connection reset"), 0, started).should be_nil
      policy.delay_for(IO::TimeoutError.new("Connect timed out"), 0).should_not be_nil
      policy.delay_for(IO::TimeoutError.new("Read timed out"), 0).should be_nil
    end
  end

  it "stops waiting when the context is cancelled" do
    ctx = Arcana::AI::Context.new
    spawn { sleep 30.milliseconds; ctx.cancel }
    t0 = Time.instant
    expect_raises(Arcana::AI::CancelledError) do
      Arcana::AI::RetryPolicy.new.run(ctx) { raise api_error(429, retry_after: 5.seconds) }
    end
    (Time.instant - t0).should be < 1.second
  end

  it "none raises the first failure" do
    calls = 0
    expect_raises(Arcana::AI::APIError) do
      Arcana::AI::RetryPolicy.none.run { calls += 1; raise api_error(503) }
    end
    calls.should eq(1)
  end
end

describe "chat providers retrying" do
  it "OpenAI waits as asked after a 429 and reports the retry" do
    with_replies([Reply.new(429, "{}", {"retry-after-ms" => "20"}), Reply.new(200, OPENAI_OK)]) do |url, seen|
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions")
      response = chat.complete(chat_request)
      response.content.should eq("hi")
      response.retries.should eq(1)
      response.retry_wait.should eq(20.milliseconds)
      seen.size.should eq(2)
    end
  end

  it "OpenAI never retries insufficient_quota" do
    with_replies([Reply.new(429, %({"error":{"code":"insufficient_quota","type":"insufficient_quota"}}))]) do |url, seen|
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions")
      expect_raises(Arcana::AI::APIError, /insufficient_quota/) { chat.complete(chat_request) }
      seen.size.should eq(1)
    end
  end

  it "gives up after max_retries and raises the last error" do
    with_replies([Reply.new(503, "busy")]) do |url, seen|
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions")
      chat.retry_policy = FAST
      expect_raises(Arcana::AI::APIError, /503/) { chat.complete(chat_request) }
      seen.size.should eq(4)
    end
  end

  it "retries the cancellable path too" do
    with_replies([Reply.new(500, "oops"), Reply.new(200, OPENAI_OK)]) do |url, _|
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions")
      chat.retry_policy = FAST
      chat.complete(chat_request, Arcana::AI::Context.new).retries.should eq(1)
    end
  end

  it "retries a stream before it starts, and streams the content once" do
    sse = %(data: {"model":"gpt-x","choices":[{"delta":{"content":"hi"}}]}\n\n) +
          %(data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n)
    with_replies([Reply.new(503, "busy"), Reply.new(200, sse, content_type: "text/event-stream")]) do |url, _|
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions")
      chat.retry_policy = FAST
      deltas = [] of String
      response = chat.stream(chat_request) do |event|
        event.text.try { |t| deltas << t } if event.type == Arcana::AI::Chat::StreamEvent::Type::TextDelta
      end
      deltas.should eq(["hi"])
      response.content.should eq("hi")
      response.retries.should eq(1)
    end
  end

  it "Anthropic retries 529 overloaded" do
    with_replies([Reply.new(529, %({"type":"error","error":{"type":"overloaded_error"}})), Reply.new(200, ANTHROPIC_OK)]) do |url, _|
      chat = Arcana::AI::Chat::Anthropic.new(api_key: "sk", endpoint: "#{url}/v1/messages")
      chat.retry_policy = FAST
      response = chat.complete(chat_request)
      response.content.should eq("hi")
      response.retries.should eq(1)
    end
  end

  it "Gemini waits for the retryDelay in its 429 body" do
    limited = %({"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"0.02s"}]}})
    with_replies([Reply.new(429, limited), Reply.new(200, GEMINI_OK)]) do |url, seen|
      chat = Arcana::AI::Chat::Gemini.new(api_key: "k", endpoint: "#{url}/v1beta")
      response = chat.complete(chat_request)
      response.content.should eq("hi")
      response.retry_wait.should eq(20.milliseconds)
      seen.last.should end_with(":generateContent")
    end
  end

  it "traces each retry" do
    with_replies([Reply.new(502, "bad gateway"), Reply.new(200, OPENAI_OK)]) do |url, _|
      events = [] of JSON::Any
      chat = Arcana::AI::Chat::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/chat/completions",
        trace: ->(e : String) { events << JSON.parse(e); nil })
      chat.retry_policy = FAST
      chat.complete(chat_request)
      retry_event = events.find { |e| e["phase"] == "api_retry" }.not_nil!
      retry_event["attempt"].should eq(1)
      retry_event["reason"].should eq("status 502")
    end
  end
end

describe "Embed::Provider#embed_with_retry" do
  it "uses the shared policy and records retries" do
    ok = %({"data":[{"embedding":[0.1,0.2],"index":0}],"model":"m","usage":{"prompt_tokens":1,"total_tokens":1}})
    with_replies([Reply.new(503, "busy"), Reply.new(200, ok)]) do |url, _|
      embed = Arcana::AI::Embed::OpenAI.new(api_key: "sk", endpoint: "#{url}/v1/embeddings")
      result = embed.embed_with_retry(Arcana::AI::Embed::Request.new(texts: ["x"]), base_delay: 0.001)
      result.embedding.should eq([0.1, 0.2])
      result.retries.should eq(1)
    end
  end
end
