require "spec_helper"

RSpec.describe GrillMe::Assembler do
  let(:env) { { "OPENAI_API_KEY" => "x", "BRAVE_SEARCH_API_KEY" => "y" } }
  let(:config) { GrillMe::Config.new(env: env) }
  let(:now) { Time.utc(2026, 5, 8, 12, 0, 0) }
  let(:assembler) { described_class.new(config: config, now: now) }

  it "builds a schema-valid artifact for the hardcoded Arsenal slice" do
    club = GrillMe::Input.from_args(name: "Arsenal", country: "England")
    artifact = assembler.build(club: club)

    expect(GrillMe::Schema.valid_club?(artifact)).to be true
    expect(artifact["status"]).to eq("complete")
    expect(artifact["counts"]).to eq("success" => 1, "failed" => 0)
    expect(artifact["players"].first["name"]).to eq("Thierry Henry")
    expect(artifact["as_of"]).to eq("2026-05-08")
    expect(artifact["window_years"]).to eq(20)
  end

  it "marks status partial when no hardcoded data is available" do
    club = GrillMe::Input.from_args(name: "UnknownClub", country: "Nowhere")
    artifact = assembler.build(club: club)

    expect(artifact["status"]).to eq("partial")
    expect(artifact["players"]).to eq([])
    expect(GrillMe::Schema.valid_club?(artifact)).to be true
  end
end
