require "../spec_helper"

describe Arcana::AI::Chat::ThinkingConfig do
  describe ".from_json" do
    it "returns nil for nil input" do
      Arcana::AI::Chat::ThinkingConfig.from_json(nil).should be_nil
    end

    it "returns enabled config for `true`" do
      cfg = Arcana::AI::Chat::ThinkingConfig.from_json(JSON::Any.new(true)).not_nil!
      cfg.enabled.should be_true
      cfg.budget.should be_nil
      cfg.effort.should be_nil
    end

    it "returns nil for `false`" do
      Arcana::AI::Chat::ThinkingConfig.from_json(JSON::Any.new(false)).should be_nil
    end

    it "parses budget from an object" do
      cfg = Arcana::AI::Chat::ThinkingConfig.from_json(
        JSON.parse(%({"budget": 2048}))
      ).not_nil!
      cfg.enabled.should be_true
      cfg.budget.should eq(2048)
    end

    it "parses effort from an object" do
      cfg = Arcana::AI::Chat::ThinkingConfig.from_json(
        JSON.parse(%({"effort": "high"}))
      ).not_nil!
      cfg.effort.should eq("high")
    end

    it "parses full config" do
      cfg = Arcana::AI::Chat::ThinkingConfig.from_json(
        JSON.parse(%({"enabled": true, "budget": 4096, "effort": "medium", "include_thoughts": false}))
      ).not_nil!
      cfg.enabled.should be_true
      cfg.budget.should eq(4096)
      cfg.effort.should eq("medium")
      cfg.include_thoughts.should be_false
    end

    it "returns nil for a non-bool, non-object input" do
      Arcana::AI::Chat::ThinkingConfig.from_json(JSON::Any.new("high")).should be_nil
    end
  end

  describe "defaults" do
    it "enabled defaults to true (any construction implies opting in)" do
      Arcana::AI::Chat::ThinkingConfig.new.enabled.should be_true
    end

    it "include_thoughts defaults to true" do
      Arcana::AI::Chat::ThinkingConfig.new.include_thoughts.should be_true
    end
  end
end
