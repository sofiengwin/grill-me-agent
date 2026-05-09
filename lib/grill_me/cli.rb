require "thor"

module GrillMe
  # Thor-based CLI entrypoint. Slice 1 only exposes the `research`
  # subcommand against a single club; later slices will add multi-club
  # input and additional flags.
  class CLI < Thor
    package_name "grill-me"

    def self.exit_on_failure?
      true
    end

    desc "research [CLUB]", "Research players who played for CLUB in the configured window"
    option :club, type: :string, desc: "Club name (alternative to positional CLUB)"
    option :country, type: :string, desc: "Country to disambiguate the club"
    option :out, type: :string, default: "out/", desc: "Output file or directory"
    option :window_years, type: :numeric, desc: "Years to look back (default 20)"
    option :concurrency, type: :numeric, desc: "Player-agent concurrency (default 5)"
    option :log_level, type: :string, desc: "debug|info|warn|error"
    def research(club_arg = nil)
      overrides = {
        window_years: options[:window_years],
        concurrency: options[:concurrency],
        log_level: options[:log_level]
      }.compact

      config = Config.new(overrides: overrides)
      logger = Log.build(level: config.log_level)

      begin
        config.validate_required_env!
      rescue ConfigError => e
        warn(e.message)
        exit(2)
      end

      club = Input.from_args(name: club_arg || options[:club], country: options[:country])
      logger.info("starting research club=#{club.name.inspect} country=#{club.country.inspect}")

      assembler = Assembler.new(config: config)
      artifact = assembler.build(club: club)
      Schema.validate_club!(artifact)

      path = Output.new(logger: logger).write(artifact: artifact, destination: options[:out])
      logger.info("done club=#{club.name.inspect} output=#{path}")
    rescue InputError, SchemaError => e
      warn(e.message)
      exit(3)
    end

    desc "version", "Print the gem version"
    def version
      puts GrillMe::VERSION
    end
  end
end
