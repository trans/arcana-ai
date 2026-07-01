require "./spec_helper"

describe Arcana::AI::Context do
  it "starts not cancelled" do
    ctx = Arcana::AI::Context.new
    ctx.cancelled?.should be_false
  end

  it "can be cancelled" do
    ctx = Arcana::AI::Context.new
    ctx.cancel
    ctx.cancelled?.should be_true
  end

  it "is safe to cancel multiple times" do
    ctx = Arcana::AI::Context.new
    ctx.cancel
    ctx.cancel
    ctx.cancelled?.should be_true
  end

  it "wait returns true when cancelled" do
    ctx = Arcana::AI::Context.new
    spawn { sleep 10.milliseconds; ctx.cancel }
    ctx.wait(1.second).should be_true
  end

  it "wait returns false on timeout" do
    ctx = Arcana::AI::Context.new
    ctx.wait(10.milliseconds).should be_false
  end
end

describe Arcana::AI::CancelledError do
  it "has default message" do
    err = Arcana::AI::CancelledError.new
    err.message.should eq("Request cancelled")
  end
end

describe "Provider cancellation" do
  it "raises CancelledError if context is already cancelled" do
    provider = Arcana::AI::Chat::OpenAI.new(api_key: "sk-test")
    ctx = Arcana::AI::Context.new
    ctx.cancel

    request = Arcana::AI::Chat::Request.new(
      messages: [Arcana::AI::Chat::Message.user("hi")],
    )

    expect_raises(Arcana::AI::CancelledError) do
      provider.complete(request, ctx)
    end
  end

  it "raises CancelledError for Anthropic if context is already cancelled" do
    provider = Arcana::AI::Chat::Anthropic.new(api_key: "sk-test")
    ctx = Arcana::AI::Context.new
    ctx.cancel

    request = Arcana::AI::Chat::Request.new(
      messages: [Arcana::AI::Chat::Message.user("hi")],
    )

    expect_raises(Arcana::AI::CancelledError) do
      provider.complete(request, ctx)
    end
  end
end
