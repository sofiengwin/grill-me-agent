module GrillMe
  # Slice 1 only supports a single club passed via CLI args (positional or
  # --club). Slice 11 extends this to file-based input (txt/yml/json) and
  # multi-club lists.
  class Input
    Club = Struct.new(:name, :country, keyword_init: true) do
      def to_h
        { name: name, country: country }.compact
      end
    end

    def self.from_args(name:, country: nil)
      raise InputError, "club name is required" if name.nil? || name.strip.empty?

      normalized_name = name.strip
      normalized_country = country&.strip
      normalized_country = nil if normalized_country&.empty?

      Club.new(name: normalized_name, country: normalized_country)
    end
  end
end
