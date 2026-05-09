require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe GrillMe::Output do
  let(:artifact) do
    {
      "schema_version" => "1.0",
      "club" => { "name" => "Arsenal", "country" => "England" }
    }
  end

  describe ".slug_for_club" do
    it "lowercases and joins with country" do
      expect(described_class.slug_for_club(name: "Arsenal", country: "England"))
        .to eq("arsenal-england")
    end

    it "strips diacritics for unicode names" do
      expect(described_class.slug_for_club(name: "Atlético Madrid"))
        .to eq("atletico-madrid")
    end

    it "collapses whitespace and punctuation to single hyphens" do
      expect(described_class.slug_for_club(name: "Real Madrid C.F."))
        .to eq("real-madrid-c-f")
    end

    it "handles missing country" do
      expect(described_class.slug_for_club(name: "Arsenal")).to eq("arsenal")
    end
  end

  describe "#write" do
    it "writes <slug>.json into the destination directory" do
      Dir.mktmpdir do |dir|
        path = described_class.new.write(artifact: artifact, destination: "#{dir}/")
        expect(path).to eq(File.join(dir, "arsenal-england.json"))
        expect(JSON.parse(File.read(path))).to eq(artifact)
      end
    end

    it "honors an explicit file path" do
      Dir.mktmpdir do |dir|
        explicit = File.join(dir, "custom.json")
        path = described_class.new.write(artifact: artifact, destination: explicit)
        expect(path).to eq(explicit)
        expect(File).to exist(explicit)
      end
    end

    it "creates parent directories that do not yet exist" do
      Dir.mktmpdir do |dir|
        nested = File.join(dir, "a", "b", "c.json")
        described_class.new.write(artifact: artifact, destination: nested)
        expect(File).to exist(nested)
      end
    end
  end
end
