require "big"
require "big/json"
require "big/yaml"
require "yaml"

module Arcana::AI
  # What calls cost at the providers' list prices, from the usage they
  # report and a table of rates.
  #
  #   case cost = response.cost
  #   in Pricing::Cost     then ledger.record(cost.total, cost.rates)
  #   in Pricing::Unpriced then log.warn(cost.detail)
  #   end
  #
  # A `Cost` is what the provider charges for that usage at the rates in
  # the table, not an estimate: rates are looked up by the model the
  # provider says answered, at the time of the call, and nothing is
  # guessed. When something can't be known (a model the table doesn't
  # have, no usage reported, a tier or region it has no rates for), the
  # answer is `Unpriced`, with the reason. Account-level terms (free
  # allowances, credits, negotiated discounts, taxes) are outside a
  # call's price; reconciling with the provider's bill is a separate step.
  #
  # The built-in table (`Table.default`) is `pricing/rates.yml`, kept to
  # the providers' published prices. Services it doesn't cover, or other
  # terms, go in a table of your own, merged over it:
  #
  #   rates = Pricing::Table.default.merge(Pricing::Table.from_yaml(File.read("rates.yml")))
  #   response.cost(table: rates)
  module Pricing
    # Rates for a model, in USD: tokens per million, web searches and
    # credits per thousand. Nil means the model has no such rate.
    class Rates
      include YAML::Serializable
      include JSON::Serializable

      getter input : BigDecimal?
      getter output : BigDecimal?
      getter cache_read : BigDecimal?
      getter cache_write : BigDecimal?
      getter cache_write_1h : BigDecimal?
      getter image_input : BigDecimal?
      getter image_output : BigDecimal?
      getter audio_output : BigDecimal?
      getter web_search : BigDecimal?
      getter credits : BigDecimal?

      def initialize(@input = nil, @output = nil, @cache_read = nil, @cache_write = nil, @cache_write_1h = nil,
                     @image_input = nil, @image_output = nil, @audio_output = nil, @web_search = nil, @credits = nil)
      end
    end

    # Other rates for prompts over `above` tokens (cache reads and writes
    # count toward it).
    class LongRates < Rates
      getter above : Int64 = 0_i64
    end

    # One model's rates from one provider, over the dates they apply.
    class Entry < Rates
      getter provider : String
      getter model : String
      getter aliases : Array(String) = [] of String
      getter long : LongRates?
      # Multipliers by the region the provider reports running a call in.
      getter geo : Hash(String, BigDecimal) = {} of String => BigDecimal
      # The first day (UTC) the rates apply, and the day they stop.
      getter since : Time?
      getter before : Time?
      # The table these rates came from: its `version`.
      property source : String = ""

      def initialize(@provider : String, @model : String, @input = nil, @output = nil, @cache_read = nil, @cache_write = nil, @cache_write_1h = nil,
                     @image_input = nil, @image_output = nil, @audio_output = nil, @web_search = nil,
                     @aliases = [] of String, @long = nil, @geo = {} of String => BigDecimal, @since = nil, @before = nil,
                     @credits = nil)
      end

      def matches?(provider : String, model : String, at : Time) : Bool
        provider == @provider && (model == @model || aliases.includes?(model)) &&
          (since.nil? || at >= since.not_nil!) && (before.nil? || at < before.not_nil!)
      end

      # The rates for a prompt of this many tokens.
      def rates_for(prompt : Int64) : Rates
        (l = long) && prompt > l.above ? l : self
      end
    end

    # Settings that apply to all of a provider's models.
    class ProviderRates
      include YAML::Serializable
      include JSON::Serializable

      getter web_search : BigDecimal?
      # Price "gpt-4o-mini-2024-07-18" as "gpt-4o-mini" unless the dated ID is listed.
      getter dated_snapshots : Bool = false

      def initialize(@web_search = nil, @dated_snapshots = false)
      end
    end

    # A set of rates, as in `pricing/rates.yml`.
    class Table
      include YAML::Serializable

      # Names the table and its edition, as "arcana-ai 2026-10-13";
      # every `Cost` priced from it carries this.
      getter version : String
      getter providers : Hash(String, ProviderRates) = {} of String => ProviderRates
      getter models : Array(Entry) = [] of Entry

      def initialize(@version : String, @models = [] of Entry, @providers = {} of String => ProviderRates)
        after_initialize
      end

      def after_initialize
        models.each { |e| e.source = version if e.source.empty? }
      end

      @@default : Table?

      # The table arcana-ai ships, from the providers' published prices.
      def self.default : Table
        @@default ||= from_yaml(BUILT_IN)
      end

      # This table with `other` laid over it: where both have rates for a
      # model, `other`'s win.
      def merge(other : Table) : Table
        Table.new("#{version} + #{other.version}", other.models + models, providers.merge(other.providers))
      end

      # The rates for a model on a date, or nil when the table has none.
      def lookup(provider : String, model : String, at : Time = Time.utc) : Entry?
        if entry = models.find(&.matches?(provider, model, at))
          return entry
        end
        if providers[provider]?.try(&.dated_snapshots) && (m = model.match(/\A(.+)-\d{4}-\d{2}-\d{2}\z/))
          models.find(&.matches?(provider, m[1], at))
        end
      end

      def web_search_rate(entry : Entry) : BigDecimal?
        entry.web_search || providers[entry.provider]?.try(&.web_search)
      end
    end

    BUILT_IN = {{ read_file("#{__DIR__}/pricing/rates.yml") }}

    # One priced part of a call.
    struct Line
      include JSON::Serializable

      # "input", "cache_read", "cache_write", "cache_write_1h", "image_input",
      # "output", "image_output", "audio_output", "web_search" or "credits",
      # or for a reported cost, what it was for.
      getter item : String
      getter quantity : Int64
      # "tokens", "searches" or "credits", or for a reported cost, what it
      # was for ("images").
      getter unit : String
      # USD per million tokens, or per thousand searches or credits; for a
      # reported cost, its USD.
      getter rate : BigDecimal
      getter amount : BigDecimal

      def initialize(@item, @quantity, @unit, @rate, @amount)
      end
    end

    # What a call costs.
    struct Cost
      include JSON::Serializable

      getter provider : String
      # The model the provider reported.
      getter model : String
      # The table's ID for it, when that differs (an alias or a dated snapshot).
      getter priced_as : String
      getter currency : String = "USD"
      getter total : BigDecimal
      getter lines : Array(Line)
      # The table the rates came from: its `version`.
      getter rates : String
      # Charges the total leaves out because they aren't set per call,
      # such as code-execution container time, billed by the hour.
      getter excluded : Array(String)

      def initialize(@provider, @model, @priced_as, @lines, @rates, @excluded = [] of String)
        @total = @lines.sum(BigDecimal.new(0), &.amount)
      end

      # A cost the provider reported itself (Runware's `includeCost`, or a
      # service that prices its own work), as one line: one `item` at
      # `total`. Its `rates` say who reported it.
      def self.reported(provider : String, model : String, total : BigDecimal, item : String = "call") : Cost
        new(provider, model, model, [Line.new(item, 1_i64, "#{item}s", total, total)], "reported by #{provider}")
      end

      # Does the total cover every charge for the call?
      def complete? : Bool
        excluded.empty?
      end
    end

    # A call that can't be priced, and why.
    struct Unpriced
      include JSON::Serializable

      enum Reason
        NoUsage      # the provider reported no usage
        UnknownModel # no rates for the provider and model on that date
        Tier         # served on a tier the rates don't cover (priority, flex, batch)
        Region       # served in a region the rates don't cover
        NoRate       # usage of a kind the model has no rate for
      end

      getter provider : String
      getter model : String
      getter reason : Reason
      getter detail : String

      def initialize(@provider : String, @model : String, @reason : Reason, @detail : String)
      end
    end

    class UnpricedError < Error
      getter unpriced : Unpriced

      def initialize(@unpriced : Unpriced)
        super(@unpriced.detail)
      end
    end

    MILLION  = BigDecimal.new(1_000_000)
    THOUSAND = BigDecimal.new(1_000)

    # Price `usage` of `model` from `provider` (the names responses carry),
    # at the rates in force at `at`.
    def self.cost(provider : String, model : String, usage : Usage?, at : Time = Time.utc, table : Table = Table.default) : Cost | Unpriced
      return Unpriced.new(provider, model, :no_usage, "#{provider} reported no usage for #{model}") unless usage
      if (tier = usage.tier) && tier != "standard"
        return Unpriced.new(provider, model, :tier, "#{provider} served #{model} on the #{tier} tier; the rates are for the standard tier")
      end
      entry = table.lookup(provider, model, at)
      return Unpriced.new(provider, model, :unknown_model, "no #{provider} rates for #{model} on #{at.to_s("%F")} in #{table.version}") unless entry

      multiplier = BigDecimal.new(1)
      if (geo = usage.geo) && geo != "global"
        multiplier = entry.geo[geo]? || return Unpriced.new(provider, model, :region, "#{provider} served #{model} in region #{geo}; #{table.version} has no rates for it")
      end

      rates = entry.rates_for(usage.prompt)
      lines = [] of Line
      {
        {"input", usage.input, rates.input},
        {"cache_read", usage.cache_read, rates.cache_read},
        {"cache_write", usage.cache_write, rates.cache_write},
        {"cache_write_1h", usage.cache_write_1h, rates.cache_write_1h},
        {"image_input", usage.image_input, rates.image_input},
        {"output", usage.output, rates.output},
        {"image_output", usage.image_output, rates.image_output},
        {"audio_output", usage.audio_output, rates.audio_output},
      }.each do |item, quantity, rate|
        next if quantity == 0
        return Unpriced.new(provider, model, :no_rate, "#{model} has no #{item} rate in #{table.version}") unless rate
        rate *= multiplier
        lines << Line.new(item, quantity, "tokens", rate, rate * quantity / MILLION)
      end
      if usage.web_searches > 0
        rate = table.web_search_rate(entry) || return Unpriced.new(provider, model, :no_rate, "#{model} has no web_search rate in #{table.version}")
        lines << Line.new("web_search", usage.web_searches, "searches", rate, rate * usage.web_searches / THOUSAND)
      end
      if usage.credits > 0
        rate = rates.credits || return Unpriced.new(provider, model, :no_rate, "#{model} has no credits rate in #{table.version}")
        lines << Line.new("credits", usage.credits, "credits", rate, rate * usage.credits / THOUSAND)
      end

      excluded = [] of String
      excluded << "code execution time" if usage.code_executions > 0
      Cost.new(provider, model, entry.model, lines, entry.source, excluded)
    end

    # As `cost`, raising `UnpricedError` when the call can't be priced.
    def self.cost!(provider : String, model : String, usage : Usage?, at : Time = Time.utc, table : Table = Table.default) : Cost
      case result = cost(provider, model, usage, at, table)
      in Cost     then result
      in Unpriced then raise UnpricedError.new(result)
      end
    end
  end

  module Chat
    struct Response
      # What this call cost; see `Pricing`. `at` is when it was made.
      def cost(at : Time = Time.utc, table : Pricing::Table = Pricing::Table.default) : Pricing::Cost | Pricing::Unpriced
        Pricing.cost(provider, model, usage, at, table)
      end
    end
  end

  module Embed
    struct Result
      # What this call cost; see `Pricing`. `at` is when it was made.
      def cost(at : Time = Time.utc, table : Pricing::Table = Pricing::Table.default) : Pricing::Cost | Pricing::Unpriced
        Pricing.cost(provider, model, usage, at, table)
      end
    end
  end
end
