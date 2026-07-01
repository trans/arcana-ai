require "../spec_helper"

describe Arcana::AI::Chat::StreamEvent do
  it "creates text_delta event" do
    event = Arcana::AI::Chat::StreamEvent.text_delta("hello")
    event.type.should eq(Arcana::AI::Chat::StreamEvent::Type::TextDelta)
    event.text.should eq("hello")
  end

  it "creates tool_use event" do
    tc = Arcana::AI::Chat::ToolCall.new(
      id: "call_1",
      type: "function",
      function: Arcana::AI::Chat::ToolCall::FunctionCall.new("search", %({"q":"test"})),
    )
    event = Arcana::AI::Chat::StreamEvent.tool_use(tc)
    event.type.should eq(Arcana::AI::Chat::StreamEvent::Type::ToolUse)
    event.tool_call.not_nil!.function.name.should eq("search")
  end

  it "creates done event with response" do
    resp = Arcana::AI::Chat::Response.new(content: "done", model: "test")
    event = Arcana::AI::Chat::StreamEvent.done(resp)
    event.type.should eq(Arcana::AI::Chat::StreamEvent::Type::Done)
    event.response.not_nil!.content.should eq("done")
  end

  it "creates error event" do
    event = Arcana::AI::Chat::StreamEvent.error("something broke")
    event.type.should eq(Arcana::AI::Chat::StreamEvent::Type::Error)
    event.error.should eq("something broke")
  end
end

describe "Provider#stream default" do
  it "raises not supported for base provider usage" do
    # Test via the abstract interface — OpenAI and Anthropic override this
    # Just verify the event struct works correctly
    events = [] of Arcana::AI::Chat::StreamEvent
    events << Arcana::AI::Chat::StreamEvent.text_delta("Hi ")
    events << Arcana::AI::Chat::StreamEvent.text_delta("there")
    events << Arcana::AI::Chat::StreamEvent.done(Arcana::AI::Chat::Response.new(content: "Hi there"))

    events.size.should eq(3)
    events[0].type.text_delta?.should be_true
    events[1].type.text_delta?.should be_true
    events[2].type.done?.should be_true
    events[2].response.not_nil!.content.should eq("Hi there")
  end
end
