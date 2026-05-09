require "spec_helper"

RSpec.describe GrillMe::Tools::WikipediaPage do
  let(:tool) { described_class.new }
  let(:fixture_path) { File.expand_path("../../fixtures/wikipedia/thierry_henry.json", __dir__) }
  let(:fixture_body) { File.read(fixture_path) }

  before do
    stub_request(:get, %r{https://en\.wikipedia\.org/w/api\.php})
      .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
  end

  describe "#fetch" do
    let(:response) { tool.fetch(title: "Thierry Henry") }
    let(:payload) { JSON.parse(response.content) }

    it "returns the canonical title and full URL" do
      expect(payload["title"]).to eq("Thierry Henry")
      expect(payload["url"]).to eq("https://en.wikipedia.org/wiki/Thierry_Henry")
    end

    it "extracts the intro paragraph as summary" do
      expect(payload["summary"]).to start_with("Thierry Daniel Henry is a French")
      expect(payload["summary"]).not_to include("Club career")
    end

    it "splits the extract into heading-keyed sections" do
      headings = payload["sections"].map { |s| s["heading"] }
      expect(headings).to eq(["Club career", "International career", "Honours"].map(&:strip))
      club_section = payload["sections"].find { |s| s["heading"] == "Club career" }
      expect(club_section["text"]).to include("Arsenal")
    end

    it "parses the infobox into a flat key/value hash" do
      expect(payload["infobox"]).to include(
        "name" => "Thierry Henry",
        "caps1" => "254",
        "clubs1" => "Arsenal"
      )
    end

    it "issues exactly one HTTP request to the MediaWiki API" do
      tool.fetch(title: "Thierry Henry")
      expect(WebMock).to have_requested(:get, %r{en\.wikipedia\.org/w/api\.php}).at_least_once
    end
  end

  describe "truncation" do
    let(:huge_extract) { "intro\n\n#{["== Big ==", "x" * 20_000].join("\n")}" }
    let(:huge_body) do
      JSON.generate(
        "query" => {
          "pages" => {
            "1" => {
              "title" => "Big",
              "fullurl" => "https://en.wikipedia.org/wiki/Big",
              "extract" => huge_extract,
              "revisions" => [{ "*" => "no infobox here" }]
            }
          }
        }
      )
    end

    it "caps section text at MAX_CONTENT_CHARS" do
      stub_request(:get, %r{https://en\.wikipedia\.org/w/api\.php})
        .to_return(status: 200, body: huge_body)

      payload = JSON.parse(described_class.new.fetch(title: "Big").content)
      total = payload["sections"].sum { |s| s["text"].length }
      expect(total).to be <= described_class::MAX_CONTENT_CHARS + "[...truncated]".length + 1
      expect(payload["sections"].last["text"]).to end_with("[...truncated]")
    end
  end

  describe "missing pages" do
    it "returns an error payload when the extract is empty" do
      stub_request(:get, %r{https://en\.wikipedia\.org/w/api\.php})
        .to_return(status: 200, body: JSON.generate(
          "query" => { "pages" => { "-1" => { "title" => "Missing", "extract" => "" } } }
        ))

      payload = JSON.parse(described_class.new.fetch(title: "Missing").content)
      expect(payload["error"]).to eq("page not found")
    end
  end
end
