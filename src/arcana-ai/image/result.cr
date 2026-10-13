module Arcana::AI
  module Image
    struct Result
      property output_path : String
      property model : String
      property provider : String      # "runware", "openai"
      property raw_request : String   # JSON request body sent to API
      property raw_response : String  # JSON response body (or status info for binary)

      # What the call used, when the provider reports it in tokens
      # (OpenAI); nil when it didn't. `cost` prices it.
      property usage : Usage?

      # What the provider said the call cost, when it says so itself
      # (Runware, or a service that prices its own work); nil otherwise.
      property reported_cost : Pricing::Cost?

      def initialize(
        @output_path : String,
        @model : String,
        @provider : String,
        cost : Pricing::Cost? = nil,
        @raw_request : String = "",
        @raw_response : String = "",
        @usage : Usage? = nil,
      )
        @reported_cost = cost
      end

      @[Deprecated("Pass a `Pricing::Cost`: `Pricing::Cost.reported(provider, model, usd, \"image\")`. Removed in arcana-ai 0.6.0.")]
      def initialize(output_path : String, model : String, provider : String, cost : Float64,
                     raw_request : String = "", raw_response : String = "", usage : Usage? = nil)
        initialize(output_path, model, provider, Pricing::Cost.reported(provider, model, BigDecimal.new(cost), "image"),
          raw_request, raw_response, usage)
      end

      # What this call cost; see `Pricing`. `at` is when it was made. The
      # provider's own figure when it reported one, otherwise its usage at
      # the table's rates.
      #
      # In arcana-ai 0.6.0 `at` gets a default, as for chat and
      # embeddings, and plain `cost` means this.
      def cost(at : Time, table : Pricing::Table = Pricing::Table.default) : Pricing::Cost | Pricing::Unpriced
        reported_cost || Pricing.cost(provider, model, usage, at, table)
      end

      @[Deprecated("Use `cost(at)` (at: when the call was made), a `Pricing::Cost` or `Pricing::Unpriced` as for chat and embeddings; it prices OpenAI images too. In arcana-ai 0.6.0 plain `cost` returns that.")]
      def cost : Float64?
        reported_cost.try(&.total.to_f)
      end

      @[Deprecated("Set `reported_cost`. Removed in arcana-ai 0.6.0.")]
      def cost=(usd : Float64?)
        @reported_cost = usd.try { |v| Pricing::Cost.reported(provider, model, BigDecimal.new(v), "image") }
      end
    end
  end
end
