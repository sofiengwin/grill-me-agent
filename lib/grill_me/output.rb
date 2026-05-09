require "fileutils"
require "json"

module GrillMe
  # Writes a finalized club artifact hash to disk as pretty-printed JSON.
  # Resolves the destination path: an explicit file path is honored
  # verbatim, an existing directory gets `<slug>.json` appended.
  class Output
    def initialize(logger: nil)
      @logger = logger
    end

    def write(artifact:, destination:, slug_hint: nil)
      path = resolve_path(destination, slug_hint || slug_for(artifact))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(artifact)}\n")
      @logger&.info("wrote #{path}")
      path
    end

    # Deterministic, filesystem-safe slug derived from the club name and
    # (when present) country. Lowercase ASCII, hyphen-separated.
    def self.slug_for_club(name:, country: nil)
      base = transliterate(name)
      base = "#{base}-#{transliterate(country)}" if country && !country.empty?
      base
    end

    def self.transliterate(value)
      value.to_s
           .unicode_normalize(:nfkd)
           .gsub(/[^\x00-\x7f]/, "")
           .downcase
           .gsub(/[^a-z0-9]+/, "-")
           .gsub(/^-+|-+$/, "")
    end

    private

    def slug_for(artifact)
      club = artifact.fetch("club")
      self.class.slug_for_club(name: club["name"], country: club["country"])
    end

    def resolve_path(destination, slug)
      if destination.end_with?("/") || File.directory?(destination)
        File.join(destination, "#{slug}.json")
      else
        destination
      end
    end
  end
end
