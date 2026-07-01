require "../spec_helper"

describe Arcana::AI::Image::Control do
  describe ".openpose" do
    it "creates an OpenPose control" do
      ctrl = Arcana::AI::Image::Control.openpose("/pose.png")
      ctrl.type.should eq(Arcana::AI::Image::Control::Type::OpenPose)
      ctrl.guide_path.should eq("/pose.png")
      ctrl.weight.should eq(0.8)
      ctrl.start_pct.should eq(0)
      ctrl.end_pct.should eq(100)
    end
  end

  describe ".canny" do
    it "creates a Canny control" do
      ctrl = Arcana::AI::Image::Control.canny("/edges.png", weight: 0.6)
      ctrl.type.should eq(Arcana::AI::Image::Control::Type::Canny)
      ctrl.weight.should eq(0.6)
    end
  end

  describe ".depth" do
    it "creates a Depth control" do
      ctrl = Arcana::AI::Image::Control.depth("/depth.png")
      ctrl.type.should eq(Arcana::AI::Image::Control::Type::Depth)
    end
  end

  describe ".flux_pose" do
    it "uses FLUX Union model with tuned defaults" do
      ctrl = Arcana::AI::Image::Control.flux_pose("/pose.png")
      ctrl.type.should eq(Arcana::AI::Image::Control::Type::OpenPose)
      ctrl.model.should eq(Arcana::AI::Image::Runware::FLUX_UNION_MODEL)
      ctrl.weight.should eq(0.9)
      ctrl.start_pct.should eq(0)
      ctrl.end_pct.should eq(65)
    end
  end
end
