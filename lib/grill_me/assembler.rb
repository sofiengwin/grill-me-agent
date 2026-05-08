require "date"

module GrillMe
  # Builds the canonical club artifact hash that downstream slices will
  # gradually fill with real agent output. Slice 1 hardcodes a single
  # well-known player so the schema, output writer, and CLI plumbing all
  # have something real to operate on end-to-end.
  class Assembler
    SCHEMA_VERSION = "1.0".freeze

    HARDCODED_PLAYERS = {
      "arsenal" => [
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
          "sources" => [
            "https://en.wikipedia.org/wiki/Thierry_Henry"
          ]
        }
      ]
    }.freeze

    def initialize(config:, now: Time.now.utc)
      @config = config
      @now = now
    end

    def build(club:)
      players = HARDCODED_PLAYERS.fetch(club.name.downcase, [])
      country = club.country || infer_country(club.name) || "Unknown"

      {
        "schema_version" => SCHEMA_VERSION,
        "club" => {
          "name" => club.name,
          "country" => country,
          "league" => players.first&.dig("club_league"),
          "wikidata_id" => nil,
          "wikipedia_url" => nil
        },
        "as_of" => @now.to_date.iso8601,
        "window_years" => @config.window_years,
        "researched_at" => @now.iso8601,
        "status" => players.empty? ? "partial" : "complete",
        "counts" => {
          "success" => players.size,
          "failed" => 0
        },
        "players" => players,
        "failed_players" => []
      }
    end

    private

    def infer_country(name)
      HARDCODED_PLAYERS[name.downcase]&.first&.dig("club_country")
    end
  end
end
