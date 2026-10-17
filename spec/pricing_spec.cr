require "./spec_helper"

private alias Pricing = Arcana::AI::Pricing
private alias Usage = Arcana::AI::Usage

private def usd(s : String) : BigDecimal
  BigDecimal.new(s)
end

private def priced(provider, model, usage, at = Time.utc, table = Pricing::Table.default) : Pricing::Cost
  Pricing.cost(provider, model, usage, at, table).as(Pricing::Cost)
end

private def reason(provider, model, usage, at = Time.utc, table = Pricing::Table.default) : Pricing::Unpriced::Reason
  Pricing.cost(provider, model, usage, at, table).as(Pricing::Unpriced).reason
end

private def date(s : String) : Time
  Time.parse_utc(s, "%F %T")
end

describe Arcana::AI::Pricing do
  describe "Anthropic" do
    it "prices every category, with the US region multiplier and web searches" do
      usage = Usage.from_anthropic(JSON.parse(%({"input_tokens": 120, "cache_read_input_tokens": 3000,
        "cache_creation_input_tokens": 500,
        "cache_creation": {"ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 300},
        "output_tokens": 42, "server_tool_use": {"web_search_requests": 2},
        "service_tier": "standard", "inference_geo": "us"})))
      cost = priced("anthropic", "claude-sonnet-5-5", usage)
      # 120 × $2.20 + 3000 × $0.11 + 200 × $2.75 + 300 × $4.40 + 42 × $11 per million, + 2 × $10 per thousand
      cost.total.should eq(usd("0.022926"))
      cost.lines.map { |l| {l.item, l.rate} }.should eq([
        {"input", usd("2.2")}, {"cache_read", usd("0.11")}, {"cache_write", usd("2.75")},
        {"cache_write_1h", usd("4.4")}, {"output", usd("11")}, {"web_search", usd("10")},
      ])
      cost.rates.should eq("arcana-ai 2026-10-13")
      cost.complete?.should be_true
    end

    it "prices an alias as the model it names" do
      cost = priced("anthropic", "claude-opus-4-0", Usage.new(input: 1_000_000))
      cost.priced_as.should eq("claude-opus-4-20250514")
      cost.total.should eq(usd("15"))
    end

    it "never prices an ID it doesn't know as another model" do
      reason("anthropic", "claude-opus-4-0-20250514", Usage.new(input: 10)).should eq(Pricing::Unpriced::Reason::UnknownModel)
      reason("anthropic", "claude-haiku-3-5-20241022", Usage.new(input: 10)).should eq(Pricing::Unpriced::Reason::UnknownModel)
    end

    it "prices Haiku 5.5 prompts over 100,000 tokens, cache included, at its long rates" do
      priced("anthropic", "claude-haiku-5-5", Usage.new(input: 100_000, output: 1000)).total.should eq(usd("0.0105"))
      priced("anthropic", "claude-haiku-5-5", Usage.new(input: 100_001, output: 1000)).total.should eq(usd("0.0525005"))
      long = priced("anthropic", "claude-haiku-5-5", Usage.new(input: 50_000, cache_read: 60_000))
      long.lines.map(&.rate).should eq([usd("0.50"), usd("0.05")])
    end

    it "won't price a region a model has no rates for" do
      reason("anthropic", "claude-sonnet-5-5", Usage.new(input: 10, geo: "eu")).should eq(Pricing::Unpriced::Reason::Region)
      reason("anthropic", "claude-sonnet-4-5", Usage.new(input: 10, geo: "us")).should eq(Pricing::Unpriced::Reason::Region)
      priced("anthropic", "claude-sonnet-4-5", Usage.new(input: 10, geo: "global")).total.should eq(usd("0.00003"))
    end

    it "leaves code-execution time out, and says so" do
      cost = priced("anthropic", "claude-sonnet-5-5", Usage.new(input: 10, code_executions: 1))
      cost.complete?.should be_false
      cost.excluded.should eq(["code execution time"])
    end
  end

  describe "OpenAI" do
    it "prices cache reads and writes apart from input" do
      usage = Usage.from_openai(JSON.parse(%({"prompt_tokens": 5000, "completion_tokens": 300,
        "prompt_tokens_details": {"cached_tokens": 3000, "cache_write_tokens": 1000}})), "default")
      # 1000 × $2 + 3000 × $0.20 + 1000 × $2.50 + 300 × $10 per million
      priced("openai", "gpt-6-sol", usage).total.should eq(usd("0.0081"))
    end

    it "prices a dated snapshot as its model, unless the snapshot has rates of its own" do
      usage = Usage.new(input: 1_000_000)
      mini = priced("openai", "gpt-4o-mini-2024-07-18", usage)
      mini.priced_as.should eq("gpt-4o-mini")
      mini.model.should eq("gpt-4o-mini-2024-07-18")
      priced("openai", "gpt-4o-2024-08-06", usage).total.should eq(usd("2.50"))
      priced("openai", "gpt-4o-2024-05-13", usage).total.should eq(usd("5"))
    end

    it "prices prompts over 272K tokens at the long rates" do
      priced("openai", "gpt-5.4", Usage.new(input: 272_000)).lines.first.rate.should eq(usd("2.50"))
      priced("openai", "gpt-5.4", Usage.new(input: 272_001)).lines.first.rate.should eq(usd("5"))
    end

    it "won't price usage of a kind the model has no rate for" do
      reason("openai", "gpt-5.4", Usage.new(input: 10, cache_write: 10)).should eq(Pricing::Unpriced::Reason::NoRate)
      reason("openai", "gpt-5.5-pro", Usage.new(input: 10, cache_read: 10)).should eq(Pricing::Unpriced::Reason::NoRate)
    end

    it "won't price a tier other than the standard one" do
      reason("openai", "gpt-4o-mini", Usage.new(input: 10, tier: "flex")).should eq(Pricing::Unpriced::Reason::Tier)
      reason("openai", "gpt-4o-mini", Usage.new(input: 10, tier: "priority")).should eq(Pricing::Unpriced::Reason::Tier)
    end

    it "stops pricing a promotional rate when the provider stops promising it" do
      usage = Usage.new(input: 100_000)
      priced("openai", "gpt-5.6-sol", usage, date("2026-11-21 23:59:59")).total.should eq(usd("0.4"))
      reason("openai", "gpt-5.6-sol", usage, date("2026-11-22 00:00:00")).should eq(Pricing::Unpriced::Reason::UnknownModel)
    end
  end

  describe "Gemini" do
    it "prices prompts over 200K tokens at the long rates, thoughts as output" do
      usage = Usage.from_gemini(JSON.parse(%({"promptTokenCount": 250000, "cachedContentTokenCount": 50000,
        "candidatesTokenCount": 800, "thoughtsTokenCount": 200, "toolUsePromptTokenCount": 40})))
      # 200,040 × $2.50 + 50,000 × $0.25 + 1000 × $15 per million
      priced("gemini", "gemini-2.5-pro", usage).total.should eq(usd("0.5276"))
    end

    it "prices a call at the rates in force when it was made" do
      usage = Usage.new(input: 1_000_000)
      priced("gemini", "gemini-3.8-flash", usage, date("2026-12-31 23:59:59")).total.should eq(usd("0.75"))
      priced("gemini", "gemini-3.8-flash", usage, date("2027-01-01 00:00:00")).total.should eq(usd("1.50"))
    end
  end

  describe "OpenAI images and speech" do
    it "prices text and image tokens at their own rates" do
      cost = priced("openai", "gpt-image-2.5-flare", Usage.new(input: 20, image_input: 1024, image_output: 196))
      cost.lines.map { |l| {l.item, l.rate} }.should eq([{"input", usd("5")}, {"image_input", usd("8")}, {"image_output", usd("30")}])
      cost.total.should eq(usd("0.014172"))
    end

    it "prices a dated image snapshot as its model" do
      priced("openai", "gpt-image-2-2026-04-21", Usage.new(image_output: 1_000_000)).total.should eq(usd("30"))
    end

    it "won't price the image models whose cached tokens go unreported" do
      %w(gpt-image-1 gpt-image-1-mini gpt-image-1.5 chatgpt-image-latest).each do |model|
        reason("openai", model, Usage.new(input: 10, image_output: 10)).should eq(Pricing::Unpriced::Reason::UnknownModel)
      end
    end

    it "won't price text output from a model that has no rate for it" do
      reason("openai", "gpt-image-2", Usage.new(input: 10, output: 5, image_output: 10)).should eq(Pricing::Unpriced::Reason::NoRate)
    end

    it "prices speech as text in and audio out" do
      cost = priced("openai", "gpt-4o-mini-tts-2025-12-15", Usage.new(input: 1_000_000, audio_output: 1_000_000))
      cost.priced_as.should eq("gpt-4o-mini-tts")
      cost.total.should eq(usd("12.60"))
    end
  end

  describe "credits" do
    mine = Pricing::Table.default.merge(Pricing::Table.from_yaml(<<-YAML))
      version: mj 2026-10-17
      models:
        - {provider: elevenlabs, model: eleven_v3, credits: 0.10}
        - {provider: elevenlabs, model: eleven_flash_v2_5, input: 1}
      YAML

    it "prices credits per thousand, at a rate from a table of your own" do
      cost = priced("elevenlabs", "eleven_v3", Usage.new(credits: 12), table: mine)
      cost.total.should eq(usd("0.0012"))
      cost.lines.map { |l| {l.item, l.quantity, l.unit} }.should eq([{"credits", 12, "credits"}])
    end

    it "has no built-in ElevenLabs rates, since a credit's price depends on the plan" do
      reason("elevenlabs", "eleven_v3", Usage.new(credits: 12)).should eq(Pricing::Unpriced::Reason::UnknownModel)
    end

    it "won't price credits for a model with no credits rate" do
      reason("elevenlabs", "eleven_flash_v2_5", Usage.new(credits: 12), table: mine).should eq(Pricing::Unpriced::Reason::NoRate)
    end
  end

  it "keeps a reported cost as it was reported" do
    cost = Pricing::Cost.reported("runware", "runware:101@1", usd("0.0038"), "image")
    {cost.total, cost.priced_as, cost.rates, cost.complete?}.should eq({usd("0.0038"), "runware:101@1", "reported by runware", true})
    JSON.parse(cost.to_json)["lines"][0]["unit"].should eq("images")
  end

  describe "embeddings" do
    it "prices the tokens reported" do
      result = Arcana::AI::Embed::Result.new(embeddings: [[0.1]], model: "text-embedding-3-small", provider: "openai",
        usage: Usage.new(input: 1_000_000))
      result.cost.as(Pricing::Cost).total.should eq(usd("0.02"))
      priced("voyage", "voyage-3", Usage.new(input: 2_000_000)).total.should eq(usd("0.12"))
    end

    it "won't price a result without usage" do
      result = Arcana::AI::Embed::Result.new(embeddings: [[0.1]], model: "text-embedding-3-small", provider: "openai")
      result.cost.as(Pricing::Unpriced).reason.should eq(Pricing::Unpriced::Reason::NoUsage)
    end
  end

  describe "tables of your own" do
    mine = Pricing::Table.from_yaml(<<-YAML)
      version: onboard 2026-10-13
      models:
        - {provider: grok, model: grok-4, input: 3, output: 15}
        - {provider: anthropic, model: claude-sonnet-5-5, input: 1, output: 5}
      YAML
    rates = Pricing::Table.default.merge(mine)

    it "adds services the built-in table doesn't have" do
      reason("grok", "grok-4", Usage.new(input: 10)).should eq(Pricing::Unpriced::Reason::UnknownModel)
      cost = priced("grok", "grok-4", Usage.new(input: 1_000_000), table: rates)
      cost.total.should eq(usd("3"))
      cost.rates.should eq("onboard 2026-10-13")
    end

    it "takes precedence over the built-in rates" do
      priced("anthropic", "claude-sonnet-5-5", Usage.new(input: 1_000_000), table: rates).total.should eq(usd("1"))
      priced("anthropic", "claude-opus-5-5", Usage.new(input: 1_000_000), table: rates).rates.should eq("arcana-ai 2026-10-13")
    end
  end

  it "raises for a call it can't price, on request" do
    expect_raises(Pricing::UnpricedError, /no openai rates for gpt-x/) do
      Pricing.cost!("openai", "gpt-x", Usage.new(input: 1))
    end
  end

  it "serializes a cost exactly" do
    json = JSON.parse(priced("anthropic", "claude-sonnet-4-5", Usage.new(input: 1000, output: 500, cache_read: 2000)).to_json)
    json["total"].to_s.should eq("0.0111")
    json["currency"].should eq("USD")
    json["priced_as"].should eq("claude-sonnet-4-5-20250929")
  end

  describe "the built-in table" do
    table = Pricing::Table.default

    it "has an input rate for every model" do
      table.models.each { |e| e.input.should_not be_nil, "#{e.provider} #{e.model}" }
    end

    it "never has two sets of rates for one model on one day" do
      table.models.each_combination(2) do |(a, b)|
        next unless a.provider == b.provider
        next if (([a.model] + a.aliases) & ([b.model] + b.aliases)).empty?
        overlap = (a.before.nil? || b.since.nil? || b.since.not_nil! < a.before.not_nil!) &&
                  (b.before.nil? || a.since.nil? || a.since.not_nil! < b.before.not_nil!)
        overlap.should be_false, "#{a.provider} #{a.model} overlaps #{b.model}"
      end
    end
  end
end
