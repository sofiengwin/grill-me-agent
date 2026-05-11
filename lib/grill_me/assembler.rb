require "date"

module GrillMe
  # Builds the canonical club artifact hash from a set of player records.
  # Slice 2 supplies a single record from one real `PlayerAgent` run; later
  # slices replace the caller-side composition with a Roster Agent and
  # a parallel Player Agent fan-out.
  class Assembler
    SCHEMA_VERSION = "1.0".freeze

    def initialize(config:, window: nil, now: Time.now.utc)
      @config = config
      @window = window
      @now = now
    end

    # @param club [GrillMe::Input::Club]
    # @param players [Array<Hash>] player records validated by the agent
    # @param failed_players [Array<Hash>] `{name:, reason:}` entries for failures
    def build(club:, players: [], failed_players: [])
      filtered_players, new_failed = partition_players(players)
      all_failed = failed_players + new_failed
      country = club.country || filtered_players.first&.dig("club_country") || "Unknown"

      {
        "schema_version" => SCHEMA_VERSION,
        "club" => {
          "name" => club.name,
          "country" => country,
          "league" => filtered_players.first&.dig("club_league"),
          "wikidata_id" => nil,
          "wikipedia_url" => nil
        },
        "as_of" => as_of_iso8601,
        "window_years" => @config.window_years,
        "researched_at" => @now.iso8601,
        "status" => (filtered_players.any? && all_failed.empty?) ? "complete" : "partial",
        "counts" => {
          "success" => filtered_players.size,
          "failed" => all_failed.size
        },
        "players" => filtered_players,
        "failed_players" => all_failed
      }
    end

    private

    def partition_players(players)
      filtered = []
      new_failed = []
      players.each do |player|
        if @window && !@window.includes?(player["start"], player["end"])
          new_failed << { "name" => player["name"], "reason" => "window_filter_excluded" }
          next
        end

        appearances = player["appearances"]
        if appearances.is_a?(Integer) && appearances < 1
          new_failed << { "name" => player["name"], "reason" => "senior_team_filter_excluded" }
          next
        end

        filtered << player
      end
      [filtered, new_failed]
    end

    def as_of_iso8601
      return @window.as_of.iso8601 if @window

      @now.to_date.iso8601
    end
  end
end
