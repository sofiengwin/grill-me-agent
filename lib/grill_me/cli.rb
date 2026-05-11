require "thor"
require "date"

module GrillMe
  # Thor-based CLI entrypoint. The `research` subcommand runs the
  # `RosterAgent` to discover players for the club, then sequentially
  # runs `PlayerAgent` for each discovered player, and finally hands the
  # results to `Assembler` for the final artifact.
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

      roster_agent = Agents::RosterAgent.new(
        llm: llm,
        tools: [Tools::WikipediaSearch.new, Tools::WikipediaPage.new]
      )
      roster = roster_agent.run(club_name: club.name, club_country: club.country)
      logger.info("roster discovered club=#{club.name.inspect} size=#{roster.size}")

      players = []
      failed_players = []
      roster.each do |player|
        player_name = player["name"]
        player_agent = Agents::PlayerAgent.new(llm: llm, tools: [Tools::WikipediaPage.new])
        logger.info("player agent name=#{player_name.inspect} club=#{club.name.inspect}")
        begin
          record = player_agent.run(player_name: player_name, club_name: club.name, club_country: club.country)
          players << record
        rescue Agents::PlayerAgent::AgentError => e
          logger.warn("player agent failed name=#{player_name.inspect} reason=#{e.message}")
          failed_players << { "name" => player_name, "reason" => e.message }
        end
      end

      window = GrillMe::Window.new(as_of: config.as_of_date || Date.today, years: config.window_years)
      assembler = Assembler.new(config: config, window: window)
      artifact = assembler.build(club: club, players: players, failed_players: failed_players)
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
