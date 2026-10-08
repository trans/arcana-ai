module Arcana::AI
  module Embed
    abstract class Provider
      include Arcana::AI::Traceable

      abstract def embed(request : Request) : Result
      abstract def name : String

      # Embed texts in batches, aggregating results.
      def batch_embed(request : Request, batch_size : Int32 = 100) : Result
        texts = request.texts
        return embed(request) if texts.size <= batch_size

        all_embeddings = [] of Array(Float64)
        all_token_counts = [] of Int32
        total_tokens = 0
        raw_requests = [] of String
        raw_responses = [] of String
        model_name = ""
        provider_name = ""

        texts.each_slice(batch_size) do |batch|
          batch_request = Request.new(
            texts: batch,
            model: request.model,
            dimensions: request.dimensions,
            input_type: request.input_type,
            trace_tags: request.trace_tags,
          )
          result = embed(batch_request)

          all_embeddings.concat(result.embeddings)
          all_token_counts.concat(result.token_counts)
          total_tokens += result.total_tokens
          raw_requests << result.raw_request
          raw_responses << result.raw_response
          model_name = result.model
          provider_name = result.provider
        end

        Result.new(
          embeddings: all_embeddings,
          token_counts: all_token_counts,
          total_tokens: total_tokens,
          model: model_name,
          provider: provider_name,
          raw_request: raw_requests.join("\n---\n"),
          raw_response: raw_responses.join("\n---\n"),
        )
      end

      # Embed, retrying rate limits, server errors and network errors the
      # way chat calls do (see `RetryPolicy`), including waiting as long as
      # the provider asks. The result records the retries.
      def embed_with_retry(request : Request, max_retries : Int32 = 3, base_delay : Float64 = 1.0) : Result
        policy = RetryPolicy.new(max_retries: max_retries, base_delay: base_delay.seconds)
        result, stats = policy.run { embed(request) }
        result.retries = stats.retries
        result.retry_wait = stats.waited
        result
      end

      # Combines batching and retry.
      def batch_embed_with_retry(request : Request, batch_size : Int32 = 100, max_retries : Int32 = 3) : Result
        texts = request.texts
        return embed_with_retry(request, max_retries) if texts.size <= batch_size

        all_embeddings = [] of Array(Float64)
        all_token_counts = [] of Int32
        total_tokens = 0
        raw_requests = [] of String
        raw_responses = [] of String
        model_name = ""
        provider_name = ""
        retries = 0
        retry_wait = Time::Span.zero

        texts.each_slice(batch_size) do |batch|
          batch_request = Request.new(
            texts: batch,
            model: request.model,
            dimensions: request.dimensions,
            input_type: request.input_type,
            trace_tags: request.trace_tags,
          )
          result = embed_with_retry(batch_request, max_retries)

          all_embeddings.concat(result.embeddings)
          all_token_counts.concat(result.token_counts)
          total_tokens += result.total_tokens
          raw_requests << result.raw_request
          raw_responses << result.raw_response
          model_name = result.model
          provider_name = result.provider
          retries += result.retries
          retry_wait += result.retry_wait
        end

        combined = Result.new(
          embeddings: all_embeddings,
          token_counts: all_token_counts,
          total_tokens: total_tokens,
          model: model_name,
          provider: provider_name,
          raw_request: raw_requests.join("\n---\n"),
          raw_response: raw_responses.join("\n---\n"),
        )
        combined.retries = retries
        combined.retry_wait = retry_wait
        combined
      end
    end
  end
end
