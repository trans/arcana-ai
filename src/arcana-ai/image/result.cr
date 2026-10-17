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

      # What this call cost; see `Pricing`. `at` is when it was made. The
      # provider's own figure when it reported one, otherwise its usage at
      # the table's rates.
      def cost(at : Time = Time.utc, table : Pricing::Table = Pricing::Table.default) : Pricing::Cost | Pricing::Unpriced
        reported_cost || Pricing.cost(provider, model, usage, at, table)
      end
    end
  end
end
