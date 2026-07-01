require "./spec_helper"

describe Arcana::AI::Error do
  it "is an Exception" do
    err = Arcana::AI::Error.new("boom")
    err.should be_a(Exception)
    err.message.should eq("boom")
  end
end

describe Arcana::AI::ConfigError do
  it "is an Arcana::AI::Error" do
    err = Arcana::AI::ConfigError.new("missing key")
    err.should be_a(Arcana::AI::Error)
  end
end

describe Arcana::AI::APIError do
  it "captures status code and response body" do
    err = Arcana::AI::APIError.new(429, "rate limited", "openai")
    err.status_code.should eq(429)
    err.response_body.should eq("rate limited")
    err.message.not_nil!.should contain("429")
    err.message.not_nil!.should contain("openai")
  end
end
