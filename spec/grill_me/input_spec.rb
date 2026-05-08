require "spec_helper"

RSpec.describe GrillMe::Input do
  describe ".from_args" do
    it "returns a Club struct with normalized name and country" do
      club = described_class.from_args(name: "  Arsenal  ", country: " England ")
      expect(club.name).to eq("Arsenal")
      expect(club.country).to eq("England")
    end

    it "leaves country nil when not supplied" do
      club = described_class.from_args(name: "Arsenal")
      expect(club.country).to be_nil
    end

    it "treats blank country as nil" do
      club = described_class.from_args(name: "Arsenal", country: "   ")
      expect(club.country).to be_nil
    end

    it "raises InputError on missing name" do
      expect { described_class.from_args(name: nil) }.to raise_error(GrillMe::InputError)
      expect { described_class.from_args(name: "  ") }.to raise_error(GrillMe::InputError)
    end
  end
end
