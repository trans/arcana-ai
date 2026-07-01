require "../spec_helper"

describe Arcana::AI::Image::Request do
  describe "defaults" do
    it "uses sensible defaults" do
      req = Arcana::AI::Image::Request.new(prompt: "a cat")
      req.width.should eq(1024)
      req.height.should eq(1024)
      req.output_format.should eq("WEBP")
      req.enhance_prompt.should be_false
      req.identity.should be_nil
      req.control.should be_nil
    end
  end

  it "accepts identity and control" do
    id = Arcana::AI::Image::Identity.seed_image("/ref.png")
    ctrl = Arcana::AI::Image::Control.openpose("/pose.png")

    req = Arcana::AI::Image::Request.new(
      prompt: "a character",
      width: 768, height: 1024,
      identity: id,
      control: ctrl,
      enhance_prompt: true,
    )

    req.identity.not_nil!.method.should eq(Arcana::AI::Image::Identity::Method::SeedImage)
    req.control.not_nil!.type.should eq(Arcana::AI::Image::Control::Type::OpenPose)
    req.enhance_prompt.should be_true
  end
end
