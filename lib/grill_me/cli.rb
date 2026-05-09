require "thor"

module GrillMe
  # Thor-based CLI entrypoint. Slice 2 wires the `research` subcommand up
  # to one real `PlayerAgent` invocation. The roster step (slice 3+) and
  # multi-club input (slice 11) still come later, so the agent input is
  # hardcoded to Thierry Henry / Arsenal for now.
  class CLI < Thor
    package_name "grill-me"

    HARDCODED_PLAYER_NAME = "Thierry Henry".freeze
    HARDCODED_PLAYER_CLUB = "Arsenal".freeze

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

      players, failed = run_player_agent(club: club, config: config, logger: logger)

      assembler = Assembler.new(config: config)
      artifact = assembler.build(club: club, players: players, failed_players: failed)
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

    no_commands do
      def run_player_agent(club:, config:, logger:)
        return [[], []] unless club.name.casecmp(HARDCODED_PLAYER_CLUB).zero?

        llm = Llm.build(
          model: options[:model] || Llm::DEFAULT_MODEL,
          api_key: config.openai_api_key
        )
        agent = Agents::PlayerAgent.new(llm: llm)
        logger.info("player agent name=#{HARDCODED_PLAYER_NAME.inspect} club=#{club.name.inspect}")
        record = agent.run(player_name: HARDCODED_PLAYER_NAME, club_name: club.name, club_country: club.country)
        [[record], []]
      rescue Agents::PlayerAgent::AgentError => e
        logger.warn("player agent failed name=#{HARDCODED_PLAYER_NAME.inspect} reason=#{e.message}")
        [[], [{ "name" => HARDCODED_PLAYER_NAME, "reason" => e.message }]]
      end
    end
  end
end
