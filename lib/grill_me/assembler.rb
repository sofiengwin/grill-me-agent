require "date"

module GrillMe
  # Builds the canonical club artifact hash from a set of player records.
  # Slice 2 supplies a single record from one real `PlayerAgent` run; later
  # slices replace the caller-side composition with a Roster Agent and
  # a parallel Player Agent fan-out.
  class Assembler
    SCHEMA_VERSION = "1.0".freeze

    def initialize(config:, now: Time.now.utc)
      @config = config
      @now = now
    end

    # @param club [GrillMe::Input::Club]
    # @param players [Array<Hash>] player records validated by the agent
    # @param failed_players [Array<Hash>] `{name:, reason:}` entries for failures
    def build(club:, players: [], failed_players: [])
      country = club.country || players.first&.dig("club_country") || "Unknown"

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
          "failed" => failed_players.size
        },
        "players" => players,
        "failed_players" => failed_players
      }
    end
  end
end
