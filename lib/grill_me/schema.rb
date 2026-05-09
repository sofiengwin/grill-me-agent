require "json"
require "json_schemer"

module GrillMe
  # Loads the canonical club artifact JSON Schema (PLAN §4) and validates
  # in-memory artifact hashes against it. Validation failures raise
  # GrillMe::SchemaError with the list of validator errors.
  class Schema
    SCHEMA_PATH = File.expand_path("schemas/club.schema.json", __dir__)

    class << self
      def club
        @club ||= JSONSchemer.schema(raw_schema)
      end

      # The player sub-schema, resolved out of $defs so callers can validate
      # a single player record returned by the Player Agent in isolation.
      # The full $defs map travels along with the sub-schema so the
      # `#/$defs/partial_date` references inside the player schema still
      # resolve when validated standalone.
      def player
        @player ||= JSONSchemer.schema(
          raw_schema.fetch("$defs").fetch("player").merge("$defs" => raw_schema.fetch("$defs"))
        )
      end

      def validate_club!(artifact)
        errors = club.validate(artifact).to_a
        return if errors.empty?

        raise SchemaError, format_errors(errors)
      end

      def valid_club?(artifact)
        club.valid?(artifact)
      end

      def player_errors(record)
        player.validate(record).to_a
      end

      def valid_player?(record)
        player.valid?(record)
      end

      private

      def raw_schema
        @raw_schema ||= JSON.parse(File.read(SCHEMA_PATH))
      end

      def format_errors(errors)
        lines = errors.first(10).map do |err|
          "  - #{err["data_pointer"].empty? ? "/" : err["data_pointer"]}: #{err["error"]}"
        end
        truncated = errors.size > 10 ? "\n  ... (+#{errors.size - 10} more)" : ""
        "Artifact failed schema validation:\n#{lines.join("\n")}#{truncated}"
      end
    end
  end
end
