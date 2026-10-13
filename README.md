# arcana-ai

Provider-agnostic AI client library for Crystal. Chat, image, TTS, SFX,
and embedding providers behind a common interface.

Extracted from [arcana](https://github.com/trans/arcana) so it can be
used without pulling in the bus/server. Usable standalone as an AI
client library, or as a dependency of arcana itself.

## Providers

- **Chat:** OpenAI (endpoint-configurable — also drives Grok, DeepSeek),
  Anthropic (native Messages API), Gemini (native API)
- **Image:** OpenAI (DALL-E / gpt-image-1), Runware (FLUX)
- **TTS:** OpenAI (gpt-4o-mini-tts), ElevenLabs
- **SFX:** ElevenLabs
- **Embed:** OpenAI, Voyage (with query/document input types)

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  arcana-ai:
    github: trans/arcana-ai
    version: ~> 0.5.1
```

Then `shards install`.

## Usage

```crystal
require "arcana-ai"

chat = Arcana::AI::Chat::Anthropic.new(api_key: ENV["ANTHROPIC_API_KEY"])
request = Arcana::AI::Chat::Request.new(
  messages: [Arcana::AI::Chat::Message.new("user", "Hello!")],
  model: "claude-sonnet-4-6",
  max_tokens: 200,
)
response = chat.complete(request)
puts response.content
```

Images in a message (a file or bytes, or a URL the provider fetches):

```crystal
Arcana::AI::Chat::Message.user("What does this picture show?", images: [
  Arcana::AI::Chat::ImagePart.file("room.webp", detail: "low"),
])
```

Chat calls retry rate limits (429), server errors (500, 502, 503, 504,
Anthropic's 529) and network errors up to 3 times, waiting as long as the
provider asks (`Retry-After`, Gemini's `retryDelay`) or backing off
0.5 s, 1 s, 2 s with jitter. They never retry OpenAI's `insufficient_quota`.
`response.retries` and `response.retry_wait` say what happened; set
`chat.retry_policy = Arcana::AI::RetryPolicy.none` to turn it off.

Via the registry:

```crystal
provider = Arcana::AI::Registry.create_chat("anthropic", {
  "api_key" => JSON::Any.new(ENV["ANTHROPIC_API_KEY"]),
})
```

## What calls cost

Each chat response and embedding result carries `usage`: what the call
used, in the categories providers bill by (uncached input, cache reads,
cache writes, output with reasoning included, web searches), the same for
every provider. It's nil when the provider reported none, never zero.

`cost` prices it at the provider's list rates:

```crystal
case cost = response.cost
in Arcana::AI::Pricing::Cost
  cost.total     # => 0.0111 (BigDecimal, USD)
  cost.lines     # input, cache_read, output..., each with its rate
  cost.rates     # => "arcana-ai 2026-10-12", the rate table used
in Arcana::AI::Pricing::Unpriced
  cost.reason    # NoUsage, UnknownModel, Tier, Region or NoRate
  cost.detail
end
```

A `Cost` isn't an estimate. The rates come from the providers' pricing
pages (`src/arcana-ai/pricing/rates.yml`) and are looked up by the model
the provider says answered, at the time of the call. Prices that change
with prompt length, US-only inference on Anthropic, and dated price
changes are all applied. What can't be known isn't guessed: a model
missing from the table, a call with no usage, or a tier or region without
rates comes back `Unpriced`. Account-level terms (free allowances, credits,
discounts, taxes) are outside a call's price. `cost.complete?` is false
when the total leaves out a charge that isn't set per call, such as
Anthropic code-execution time.

Other services, or other terms, go in a table of your own laid over the
built-in one. Pass `name:` to a provider pointed at an OpenAI-compatible
service so its responses carry that name:

```crystal
rates = Arcana::AI::Pricing::Table.default.merge(Arcana::AI::Pricing::Table.from_yaml(<<-YAML))
  version: my-app 2026-10-13
  models:
    - {provider: my-gateway, model: my-model, input: 0.50, output: 1.50}
  YAML
response.cost(table: rates)
Arcana::AI::Pricing.cost(provider, model, usage, at: logged_at, table: rates) # price a stored call
```

The older counts in each provider's own terms (`Chat::Response`'s
`prompt_tokens`, `completion_tokens`, `cache_read_tokens`,
`cache_creation_tokens` and `reasoning_tokens`, and `Embed::Result`'s
`total_tokens`) are deprecated: the compiler warns where you use them,
naming what replaces each. They go away in 0.6.0.

## Development

```
crystal spec
```

## License

MIT
