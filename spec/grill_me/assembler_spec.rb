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

  describe "with window filtering" do
    let(:as_of) { Date.new(2026, 5, 8) }
    let(:window) { GrillMe::Window.new(as_of: as_of, years: 20) }
    let(:assembler) { described_class.new(config: config, window: window, now: now) }
    let(:club) { GrillMe::Input.from_args(name: "Arsenal", country: "England") }

    let(:outside_window_player) do
      henry_record.merge("name" => "Old Player", "start" => "1980-01", "end" => "1985-06")
    end

    let(:zero_appearances_player) do
      henry_record.merge("name" => "Bench Warmer", "appearances" => 0)
    end

    it "uses window.as_of for the artifact as_of field" do
      artifact = assembler.build(club: club, players: [henry_record])
      expect(artifact["as_of"]).to eq("2026-05-08")
    end

    it "excludes players outside the window with reason window_filter_excluded" do
      artifact = assembler.build(club: club, players: [henry_record, outside_window_player])

      expect(artifact["players"].map { |p| p["name"] }).to eq(["Thierry Henry"])
      excluded = artifact["failed_players"].find { |f| f["name"] == "Old Player" }
      expect(excluded["reason"]).to eq("window_filter_excluded")
      expect(artifact["counts"]).to eq("success" => 1, "failed" => 1)
      expect(artifact["status"]).to eq("partial")
    end

    it "excludes players with zero appearances with reason senior_team_filter_excluded" do
      artifact = assembler.build(club: club, players: [henry_record, zero_appearances_player])

      expect(artifact["players"].map { |p| p["name"] }).to eq(["Thierry Henry"])
      excluded = artifact["failed_players"].find { |f| f["name"] == "Bench Warmer" }
      expect(excluded["reason"]).to eq("senior_team_filter_excluded")
      expect(artifact["status"]).to eq("partial")
    end

    it "marks status complete when no filters hit and no upstream failures" do
      artifact = assembler.build(club: club, players: [henry_record])

      expect(artifact["status"]).to eq("complete")
      expect(artifact["failed_players"]).to eq([])
      expect(GrillMe::Schema.valid_club?(artifact)).to be true
    end

    it "marks status partial when filters remove a player even with upstream successes" do
      artifact = assembler.build(club: club, players: [henry_record, zero_appearances_player])
      expect(artifact["status"]).to eq("partial")
    end

    it "concatenates upstream failures with filter failures" do
      upstream_failure = { "name" => "Missing Player", "reason" => "max_iterations_reached" }
      artifact = assembler.build(
        club: club,
        players: [henry_record, zero_appearances_player],
        failed_players: [upstream_failure]
      )

      reasons = artifact["failed_players"].map { |f| f["reason"] }
      expect(reasons).to include("max_iterations_reached", "senior_team_filter_excluded")
      expect(artifact["counts"]).to eq("success" => 1, "failed" => 2)
    end
  end
end
