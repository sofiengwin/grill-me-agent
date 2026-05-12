require "thor"
require "date"

module GrillMe
  # Thor-based CLI entrypoint. The `research` subcommand wires up the
  # configuration, logger, LLM, window, assembler, and output writer,
  # then delegates the per-club pipeline to `Runner`.
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
    option :model, type: :string, desc: "OpenAI chat model (default gpt-4o-mini)"
    option :as_of, type: :string, desc: "Override reference date YYYY-MM-DD"
    def research(club_arg = nil)
      overrides = {
        window_years: options[:window_years],
        concurrency: options[:concurrency],
        log_level: options[:log_level],
        as_of: options[:as_of]
      }.compact

      begin
        config = Config.new(overrides: overrides)
      rescue ConfigError => e
        warn(e.message)
        exit(2)
      end
      logger = Log.build(level: config.log_level)

      begin
        config.validate_required_env!
      rescue ConfigError => e
        warn(e.message)
        exit(2)
      end

      club = Input.from_args(name: club_arg || options[:club], country: options[:country])
      logger.info("starting research club=#{club.name.inspect} country=#{club.country.inspect}")

      llm = Llm.build(
        model: options[:model] || Llm::DEFAULT_MODEL,
        api_key: config.openai_api_key
      )

      window = GrillMe::Window.new(as_of: config.as_of_date || Date.today, years: config.window_years)
      assembler = Assembler.new(config: config, window: window)
      output = Output.new(logger: logger)

      runner = Runner.new(
        config: config,
        logger: logger,
        llm: llm,
        window: window,
        assembler: assembler,
        output: output
      )
      runner.run(club: club)
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
