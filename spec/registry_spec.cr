require "./spec_helper"

describe Arcana::AI::Registry do
  describe "built-in providers" do
    it "lists openai as a chat provider" do
      Arcana::AI::Registry.chat_providers.should contain("openai")
    end

    it "lists openai and runware as image providers" do
      Arcana::AI::Registry.image_providers.should contain("openai")
      Arcana::AI::Registry.image_providers.should contain("runware")
    end

    it "lists openai as a TTS provider" do
      Arcana::AI::Registry.tts_providers.should contain("openai")
    end

    it "lists openai as an embed provider" do
      Arcana::AI::Registry.embed_providers.should contain("openai")
    end
  end

  describe "creation errors" do
    it "raises ConfigError for unknown chat provider" do
      expect_raises(Arcana::AI::ConfigError, /Unknown chat provider/) do
        Arcana::AI::Registry.create_chat("nonexistent")
      end
    end

    it "raises ConfigError for unknown image provider" do
      expect_raises(Arcana::AI::ConfigError, /Unknown image provider/) do
        Arcana::AI::Registry.create_image("nonexistent")
      end
    end

    it "raises ConfigError for unknown TTS provider" do
      expect_raises(Arcana::AI::ConfigError, /Unknown TTS provider/) do
        Arcana::AI::Registry.create_tts("nonexistent")
      end
    end

    it "raises ConfigError for unknown embed provider" do
      expect_raises(Arcana::AI::ConfigError, /Unknown embed provider/) do
        Arcana::AI::Registry.create_embed("nonexistent")
      end
    end
  end

  describe "config helpers" do
    config = Arcana::AI::Registry::Config{
      "name"  => JSON::Any.new("test"),
      "count" => JSON::Any.new(42_i64),
      "rate"  => JSON::Any.new(0.75),
      "flag"  => JSON::Any.new(true),
    }

    it ".str extracts strings" do
      Arcana::AI::Registry.str(config, "name").should eq("test")
      Arcana::AI::Registry.str(config, "missing", "default").should eq("default")
    end

    it ".int extracts integers" do
      Arcana::AI::Registry.int(config, "count").should eq(42)
      Arcana::AI::Registry.int(config, "missing", 99).should eq(99)
    end

    it ".float extracts floats" do
      Arcana::AI::Registry.float(config, "rate").should eq(0.75)
      Arcana::AI::Registry.float(config, "missing", 1.0).should eq(1.0)
    end

    it ".bool extracts booleans" do
      Arcana::AI::Registry.bool(config, "flag").should be_true
      Arcana::AI::Registry.bool(config, "missing").should be_false
    end
  end
end
