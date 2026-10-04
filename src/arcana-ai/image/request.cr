module Arcana::AI
  module Image
    struct Request
      property prompt : String
      property width : Int32
      property height : Int32
      property identity : Identity?
      property control : Control?
      property output_format : String  # "WEBP", "PNG"
      property enhance_prompt : Bool   # let provider rewrite prompt
      property trace_tags : Hash(String, String)?  # opaque metadata passed to trace events
      # Guidance for this request, in place of the provider's own (models
      # differ: FLUX dev wants about 3.5); nil keeps the provider's
      property cfg_scale : Float64?
      # A fixed seed, for reproducible images (A/B checks); nil picks one at random
      property seed : Int64?

      def initialize(
        @prompt : String,
        @width : Int32 = 1024,
        @height : Int32 = 1024,
        @identity : Identity? = nil,
        @control : Control? = nil,
        @output_format : String = "WEBP",
        @enhance_prompt : Bool = false,
        @trace_tags : Hash(String, String)? = nil,
        @cfg_scale : Float64? = nil,
        @seed : Int64? = nil,
      )
      end
    end
  end
end
