require "spec_helper"
require "open3"
require "tmpdir"
require "json"

RSpec.describe "bin/grill-me research", type: :e2e do
  let(:bin) { File.expand_path("../../bin/grill-me", __dir__) }
  let(:env) do
    {
      "OPENAI_API_KEY" => "test-openai",
      "BRAVE_SEARCH_API_KEY" => "test-brave"
    }
  end

  it "produces a schema-valid JSON file end-to-end" do
    Dir.mktmpdir do |dir|
      out_dir = "#{dir}/"
      stdout, stderr, status = Open3.capture3(env, "ruby", bin, "research", "Arsenal", "--country", "England", "--out",
                                              out_dir)

      expect(status.success?).to be(true), "exit #{status.exitstatus}\nstdout=#{stdout}\nstderr=#{stderr}"

      produced = File.join(dir, "arsenal-england.json")
      expect(File).to exist(produced)

      artifact = JSON.parse(File.read(produced))
      expect(GrillMe::Schema.valid_club?(artifact)).to be true
      expect(artifact["club"]["name"]).to eq("Arsenal")
      expect(artifact["players"].first["name"]).to eq("Thierry Henry")
      expect(stderr).to include("starting research")
      expect(stderr).to include("done")
    end
  end

  it "fails fast with exit 2 when required env vars are missing" do
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3({}, "ruby", bin, "research", "Arsenal", "--out", "#{dir}/")
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("OPENAI_API_KEY")
    end
  end
end
