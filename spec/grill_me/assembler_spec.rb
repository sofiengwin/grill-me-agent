require "spec_helper"

RSpec.describe GrillMe::Assembler do
  let(:env) { { "OPENAI_API_KEY" => "x", "BRAVE_SEARCH_API_KEY" => "y" } }
  let(:config) { GrillMe::Config.new(env: env) }
  let(:now) { Time.utc(2026, 5, 8, 12, 0, 0) }
  let(:assembler) { described_class.new(config: config, now: now) }
  let(:henry_record) do
    {
      "name" => "Thierry Henry",
      "wikidata_id" => "Q11930",
      "wikipedia_url" => "https://en.wikipedia.org/wiki/Thierry_Henry",
      "club_name" => "Arsenal",
      "club_country" => "England",
      "club_league" => "Premier League",
      "start" => "1999-08",
      "end" => "2007-06",
      "appearances" => 377,
      "confidence" => "high",
      "sources" => ["https://en.wikipedia.org/wiki/Thierry_Henry"]
    }
  end

  it "builds a schema-valid artifact from supplied player records" do
    club = GrillMe::Input.from_args(name: "Arsenal", country: "England")
    artifact = assembler.build(club: club, players: [henry_record])

    expect(GrillMe::Schema.valid_club?(artifact)).to be true
    expect(artifact["status"]).to eq("complete")
    expect(artifact["counts"]).to eq("success" => 1, "failed" => 0)
    expect(artifact["players"].first["name"]).to eq("Thierry Henry")
    expect(artifact["as_of"]).to eq("2026-05-08")
    expect(artifact["window_years"]).to eq(20)
  end

  it "marks status partial when no players are supplied" do
    club = GrillMe::Input.from_args(name: "UnknownClub", country: "Nowhere")
    artifact = assembler.build(club: club)

    expect(artifact["status"]).to eq("partial")
    expect(artifact["players"]).to eq([])
    expect(GrillMe::Schema.valid_club?(artifact)).to be true
  end

  it "records failures in counts and failed_players" do
    club = GrillMe::Input.from_args(name: "Arsenal", country: "England")
    artifact = assembler.build(club: club, players: [], failed_players: [
                                 { "name" => "Thierry Henry", "reason" => "max_iterations_reached" }
                               ])

    expect(artifact["counts"]).to eq("success" => 0, "failed" => 1)
    expect(artifact["failed_players"].first["name"]).to eq("Thierry Henry")
    expect(GrillMe::Schema.valid_club?(artifact)).to be true
  end
end
