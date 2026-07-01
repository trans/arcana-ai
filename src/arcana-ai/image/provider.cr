module Arcana::AI
  module Image
    abstract class Provider
      include Arcana::AI::Traceable

      abstract def generate(request : Request, output_path : String) : Result
      abstract def name : String
    end
  end
end
