require "spec_helper"

RSpec.describe GrillMe::Config do
  let(:full_env) do
    { "OPENAI_API_KEY" => "sk-test", "BRAVE_SEARCH_API_KEY" => "brv-test" }
  end

  describe "defaults" do
    it "uses built-in defaults when nothing is set" do
      config = described_class.new(env: full_env)
      expect(config.window_years).to eq(20)
      expect(config.concurrency).to eq(5)
      expect(config.log_level).to eq("info")
    end
  end

  describe "layered overrides" do
    it "prefers CLI overrides over env vars" do
      env = full_env.merge("GRILL_ME_WINDOW_YEARS" => "10")
      config = described_class.new(env: env, overrides: { window_years: 30 })
      expect(config.window_years).to eq(30)
    end

    it "falls back to env vars when no override is given" do
      env = full_env.merge("GRILL_ME_CONCURRENCY" => "8")
      config = described_class.new(env: env)
      expect(config.concurrency).to eq(8)
    end
  end

  describe "as_of" do
    it "defaults to nil when not provided" do
      config = described_class.new(env: full_env)
      expect(config.as_of).to be_nil
      expect(config.as_of_date).to be_nil
    end

    it "accepts a YYYY-MM-DD override and parses it as a Date" do
      config = described_class.new(env: full_env, overrides: { as_of: "2025-01-15" })
      expect(config.as_of).to eq("2025-01-15")
      expect(config.as_of_date).to eq(Date.new(2025, 1, 15))
    end

    it "reads from GRILL_ME_AS_OF env var" do
      env = full_env.merge("GRILL_ME_AS_OF" => "2024-06-01")
      config = described_class.new(env: env)
      expect(config.as_of_date).to eq(Date.new(2024, 6, 1))
    end

    it "raises ConfigError for malformed as_of" do
      expect { described_class.new(env: full_env, overrides: { as_of: "not-a-date" }) }
        .to raise_error(GrillMe::ConfigError, /as_of must be YYYY-MM-DD format/)
    end

    it "raises ConfigError for partial date precision" do
      expect { described_class.new(env: full_env, overrides: { as_of: "2025-01" }) }
        .to raise_error(GrillMe::ConfigError, /as_of must be YYYY-MM-DD format/)
    end
  end

  describe "#validate_required_env!" do
    it "passes when all required keys are present" do
      expect { described_class.new(env: full_env).validate_required_env! }.not_to raise_error
    end

    it "raises ConfigError listing every missing key" do
      expect { described_class.new(env: {}).validate_required_env! }
        .to raise_error(GrillMe::ConfigError) { |err|
          expect(err.message).to include("OPENAI_API_KEY")
          expect(err.message).to include("BRAVE_SEARCH_API_KEY")
        }
    end

    it "treats blank strings as missing" do
      env = { "OPENAI_API_KEY" => "  ", "BRAVE_SEARCH_API_KEY" => "brv" }
      expect { described_class.new(env: env).validate_required_env! }
        .to raise_error(GrillMe::ConfigError, /OPENAI_API_KEY/)
    end
  end
end
