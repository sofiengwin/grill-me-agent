require "spec_helper"

RSpec.describe GrillMe::Schema do
  let(:valid_artifact) do
    {
      "schema_version" => "1.0",
      "club" => {
        "name" => "Arsenal",
        "country" => "England",
        "league" => "Premier League",
        "wikidata_id" => nil,
        "wikipedia_url" => nil
      },
      "as_of" => "2026-05-08",
      "window_years" => 20,
      "researched_at" => "2026-05-08T00:00:00Z",
      "status" => "complete",
      "counts" => { "success" => 1, "failed" => 0 },
      "players" => [
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
      ],
      "failed_players" => []
    }
  end

  it "accepts a well-formed artifact" do
    expect(described_class.valid_club?(valid_artifact)).to be true
    expect { described_class.validate_club!(valid_artifact) }.not_to raise_error
  end

  it "rejects unknown top-level keys" do
    artifact = valid_artifact.merge("extra" => "nope")
    expect { described_class.validate_club!(artifact) }.to raise_error(GrillMe::SchemaError)
  end

  it "rejects bad partial-date formats" do
    artifact = valid_artifact.dup
    artifact["players"] = [valid_artifact["players"].first.merge("start" => "1999/08")]
    expect { described_class.validate_club!(artifact) }.to raise_error(GrillMe::SchemaError, /start/)
  end

  it "rejects out-of-range confidence values" do
    artifact = valid_artifact.dup
    artifact["players"] = [valid_artifact["players"].first.merge("confidence" => "very-high")]
    expect { described_class.validate_club!(artifact) }.to raise_error(GrillMe::SchemaError, /confidence/)
  end
end
