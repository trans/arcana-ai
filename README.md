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
    version: ~> 0.1.0
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

## Development

```
crystal spec
```

## License

MIT
