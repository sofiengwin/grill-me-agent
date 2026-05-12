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
    option :temperature, type: :numeric, desc: "LLM temperature (default 0.0, non-zero disables cache)"
    option :no_cache, type: :boolean, desc: "Bypass cache reads and writes"
    option :refresh_cache, type: :boolean, desc: "Bypass cache reads, still write"
    option :quiet, type: :boolean, desc: "Suppress info-level trace output on stderr (errors only)"
    option :verbose, type: :boolean, desc: "Enable debug-level trace output (full LLM messages)"
    def research(club_arg = nil)
      overrides = {
        window_years: options[:window_years],
        concurrency: options[:concurrency],
        log_level: options[:log_level],
        as_of: options[:as_of],
        quiet: options[:quiet],
        verbose: options[:verbose]
      }.compact

      begin
        config = Config.new(overrides: overrides)
      rescue ConfigError => e
        warn(e.message)
        exit(2)
      end
      logger = Log.build(level: config.log_level)
      trace = Trace.new(level: config.trace_level, sinks: [StderrSink.new])

      begin
        config.validate_required_env!
      rescue ConfigError => e
        warn(e.message)
        exit(2)
      end

      club = Input.from_args(name: club_arg || options[:club], country: options[:country])
      logger.info("starting research club=#{club.name.inspect} country=#{club.country.inspect}")

      temperature = options[:temperature] || Llm::DEFAULT_TEMPERATURE
      cache = options[:no_cache] ? nil : Cache.new(no_cache: false, refresh: options[:refresh_cache] || false)

      llm = Llm.build(
        model: options[:model] || Llm::DEFAULT_MODEL,
        temperature: temperature,
        api_key: config.openai_api_key,
        cache: cache
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
        output: output,
        cache: cache,
        trace: trace
      )
      runner.run(club: club)
    rescue InputError, SchemaError => e
      warn(e.message)
      exit(3)
    ensure
      trace.close if defined?(trace) && trace
    end

    desc "clear-cache", "Wipe the .cache/ directory"
    def clear_cache
      cache = GrillMe::Cache.new
      cache.clear!
      puts "Cache cleared."
    end

    desc "version", "Print the gem version"
    def version
      puts GrillMe::VERSION
    end
  end
end
