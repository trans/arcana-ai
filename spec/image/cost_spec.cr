require "../spec_helper"
require "base64"
require "http/server"

private alias Pricing = Arcana::AI::Pricing

PNG = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

# Answers POSTs with `body` and GETs (an image download) with PNG bytes,
# yielding the base URL and the request bodies seen.
private def image_server(body : String, &)
  seen = [] of String
  server = HTTP::Server.new do |ctx|
    if ctx.request.method == "GET"
      ctx.response.content_type = "image/png"
      ctx.response.write(PNG)
    else
      seen << (ctx.request.body.try(&.gets_to_end) || "")
      ctx.response.content_type = "application/json"
      ctx.response.print body.gsub("$URL", "http://#{ctx.request.headers["Host"]}")
    end
  end
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  begin
    yield "http://127.0.0.1:#{address.port}", seen
  ensure
    server.close
  end
end

private def with_tempfile(&)
  path = File.tempname("arcana-ai-image-spec-", ".png")
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

private def draw
  Arcana::AI::Image::Request.new(prompt: "a red circle", width: 1024, height: 1024)
end

describe "image costs" do
  it "prices an OpenAI image from its usage" do
    body = %({"created": 1, "data": [{"b64_json": "#{Base64.strict_encode(PNG)}"}],
      "usage": {"input_tokens": 1044, "input_tokens_details": {"image_tokens": 1024, "text_tokens": 20},
                "output_tokens": 196, "output_tokens_details": {"image_tokens": 196, "text_tokens": 0},
                "total_tokens": 1240}})
    image_server(body) do |url, seen|
      with_tempfile do |path|
        result = Arcana::AI::Image::OpenAI.new(api_key: "k", generations_endpoint: "#{url}/v1/images/generations").generate(draw, path)
        JSON.parse(seen.last)["model"].should eq("gpt-image-2.5-sunburst")
        File.open(path, &.getb_to_end).should eq(PNG)
        usage = result.usage.not_nil!
        {usage.input, usage.image_input, usage.output, usage.image_output}.should eq({20, 1024, 0, 196})
        # 20 × $5 + 1024 × $8 + 196 × $30 per million
        result.cost(Time.utc).as(Pricing::Cost).total.should eq(BigDecimal.new("0.014172"))
      end
    end
  end

  it "takes Runware's own figure as the cost" do
    body = %({"data": [{"taskType": "imageInference", "imageURL": "$URL/image.png", "cost": 0.0038}]})
    image_server(body) do |url|
      with_tempfile do |path|
        result = Arcana::AI::Image::Runware.new(api_key: "k", endpoint: url).generate(draw, path)
        File.open(path, &.getb_to_end).should eq(PNG)
        result.usage.should be_nil
        cost = result.cost(Time.utc).as(Pricing::Cost)
        cost.total.should eq(BigDecimal.new("0.0038"))
        cost.rates.should eq("reported by runware")
        cost.lines.map { |l| {l.item, l.quantity, l.unit} }.should eq([{"image", 1, "images"}])
      end
    end
  end

  it "won't price an image that came with neither usage nor a cost" do
    result = Arcana::AI::Image::Result.new("x.png", "gpt-image-2", "openai")
    result.cost(Time.utc).as(Pricing::Unpriced).reason.should eq(Pricing::Unpriced::Reason::NoUsage)
  end

  it "carries a cost a service reported" do
    cost = Pricing::Cost.reported("mj:camera", "nano-banana", BigDecimal.new("0.039"), "image")
    result = Arcana::AI::Image::Result.new("x.png", "nano-banana", "mj:camera", cost)
    result.reported_cost.should eq(cost)
    result.cost(Time.utc).as(Pricing::Cost).total.should eq(BigDecimal.new("0.039"))
  end
end
