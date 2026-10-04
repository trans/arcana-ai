require "../spec_helper"

describe Arcana::AI::Image::Runware do
  describe ".snap_dimensions" do
    it "snaps to nearest FLUX-compatible resolution" do
      w, h = Arcana::AI::Image::Runware.snap_dimensions(1000, 1000)
      # Should snap to a valid FLUX dimension pair
      w.should be > 0
      h.should be > 0
    end

    it "returns exact match when dimensions are already valid" do
      w, h = Arcana::AI::Image::Runware.snap_dimensions(1024, 1024)
      w.should eq(1024)
      h.should eq(1024)
    end

    it "handles portrait aspect ratios" do
      w, h = Arcana::AI::Image::Runware.snap_dimensions(768, 1344)
      w.should be <= h
    end

    it "handles landscape aspect ratios" do
      w, h = Arcana::AI::Image::Runware.snap_dimensions(1344, 768)
      w.should be >= h
    end
  end
end

# The payload builder is private; reach it for the spec
class Arcana::AI::Image::Runware
  def payload_for_spec(request : Arcana::AI::Image::Request) : JSON::Any
    JSON.parse(build_payload(request))[0]
  end
end

describe "Arcana::AI::Image::Runware guidance" do
  runware = Arcana::AI::Image::Runware.new(api_key: "test", cfg_scale: 14.0)

  it "uses the provider's guidance unless the request sets its own" do
    runware.payload_for_spec(Arcana::AI::Image::Request.new(prompt: "a room"))["CFGScale"].as_f.should eq(14.0)
    runware.payload_for_spec(Arcana::AI::Image::Request.new(prompt: "a room", cfg_scale: 3.5))["CFGScale"].as_f.should eq(3.5)
  end
end

describe "Arcana::AI::Image::Runware identity payloads" do
  runware = Arcana::AI::Image::Runware.new(api_key: "test")
  ref = File.tempname("ref", ".png").tap { |p| File.write(p, "png") }
  mask = File.tempname("mask", ".png").tap { |p| File.write(p, "png") }
  request = ->(id : Arcana::AI::Image::Identity) { Arcana::AI::Image::Request.new(prompt: "a face", identity: id, seed: 42_i64) }

  it "sends PuLID as a nested puLID object (top-level referenceImages is silently ignored)" do
    p = runware.payload_for_spec(request.call(Arcana::AI::Image::Identity.pulid(ref, 1.0)))
    p["puLID"]["inputImages"].as_a.size.should eq(1)
    p["puLID"]["idWeight"].as_f.should eq(1.0)
    p["referenceImages"]?.should be_nil
    p["seed"].as_i64.should eq(42)
  end

  it "sends ACE++ with `type` and its mask" do
    p = runware.payload_for_spec(request.call(Arcana::AI::Image::Identity.ace_plus(ref, mask_path: mask)))
    p["acePlusPlus"]["type"].as_s.should eq("portrait")
    p["acePlusPlus"]["inputMasks"].as_a.size.should eq(1)
    p["acePlusPlus"]["taskType"]?.should be_nil
  end

  it "fails rather than quietly drop what it can't send" do
    expect_raises(ArgumentError, /needs a mask/) { runware.payload_for_spec(request.call(Arcana::AI::Image::Identity.ace_plus(ref))) }
    expect_raises(ArgumentError, /not found/) { runware.payload_for_spec(request.call(Arcana::AI::Image::Identity.pulid("/nonexistent.png"))) }
    expect_raises(ArgumentError, /doesn't support/) { runware.payload_for_spec(request.call(Arcana::AI::Image::Identity.ip_adapter(ref))) }
  end
end
