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

  # Slice 2 swaps the hardcoded record for a real PlayerAgent run, which
  # in turn calls OpenAI. Wiring VCR into a forked binary process is
  # slice-10 work (per PLAN §10), so the full end-to-end smoke test only
  # runs under LIVE=1 today; the PlayerAgent integration spec covers the
  # cassette+replay path that CI exercises.
  it "produces a schema-valid JSON file end-to-end", :live do
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

  it "fails fast with exit 2 when --as-of is malformed" do
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = Open3.capture3(env, "ruby", bin, "research", "Arsenal",
                                               "--country", "England",
                                               "--as-of", "not-a-date",
                                               "--out", "#{dir}/")
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("as_of must be YYYY-MM-DD format")
    end
  end

  it "lists --as-of in research help output" do
    _stdout, stderr, status = Open3.capture3(env, "ruby", bin, "help", "research")
    combined = _stdout + stderr
    expect(status.exitstatus).to eq(0)
    expect(combined).to match(/--as[-_]of/)
  end
end
