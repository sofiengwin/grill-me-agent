require "concurrent"

module GrillMe
  # Orchestrates the per-club research pipeline: runs the RosterAgent to
  # discover players, fans the player records out across a fixed thread
  # pool of PlayerAgent runs, enforces a per-club wall-clock timeout, and
  # hands the assembled artifact to the Output writer.
  class Runner
    def initialize(config:, logger:, llm:, window:, assembler:, output:, cache: nil)
      @config = config
      @logger = logger
      @llm = llm
      @window = window
      @assembler = assembler
      @output = output
      @cache = cache
    end

    def run(club:)
      roster = discover_roster(club: club)

      pool = Concurrent::FixedThreadPool.new(@config.concurrency)
      futures = roster.map { |player| submit_player(pool: pool, club: club, player: player) }

      wait_for_futures(futures)

      pool.shutdown
      pool.wait_for_termination(30)

      players, failed = collect_results(futures: futures, roster: roster)

      artifact = @assembler.build(club: club, players: players, failed_players: failed)
      Schema.validate_club!(artifact)

      path = @output.write(artifact: artifact, destination: output_destination)
      @logger.info("done club=#{club.name.inspect} output=#{path}")
      path
    end

    private

    def discover_roster(club:)
      roster_agent = Agents::RosterAgent.new(llm: @llm, cache: @cache)
      roster = roster_agent.run(club_name: club.name, club_country: club.country)
      @logger.info("roster discovered club=#{club.name.inspect} size=#{roster.size}")
      roster
    end

    def submit_player(pool:, club:, player:)
      player_name = player["name"]
      logger = @logger
      llm = @llm
      cache = @cache
      Concurrent::Future.execute(executor: pool) do
        tag = "#{club.name}/player:#{player_name}"
        logger.info("[#{tag}] starting player agent")
        agent = Agents::PlayerAgent.new(llm: llm, cache: cache)
        begin
          record = agent.run(
            player_name: player_name,
            club_name: club.name,
            club_country: club.country
          )
          logger.info("[#{tag}] success")
          { type: :success, record: record }
        rescue Agents::PlayerAgent::AgentError => e
          logger.warn("[#{tag}] failed: #{e.message}")
          { type: :failure, name: player_name, reason: e.message }
        end
      end
    end

    def wait_for_futures(futures)
      timeout_s = @config.per_club_timeout_s
      deadline = Time.now + timeout_s
      futures.each do |future|
        remaining = deadline - Time.now
        break if remaining <= 0

        future.wait(remaining)
      end
    end

    def collect_results(futures:, roster:)
      players = []
      failed = []
      futures.each_with_index do |future, idx|
        if future.fulfilled?
          payload = future.value
          if payload[:type] == :success
            players << payload[:record]
          else
            failed << { "name" => payload[:name], "reason" => payload[:reason] }
          end
        else
          future.cancel if future.respond_to?(:cancel)
          failed << { "name" => roster[idx]["name"], "reason" => "per_club_timeout_reached" }
        end
      end
      [players, failed]
    end

    def output_destination
      configured = @config.respond_to?(:output_dir) ? @config.output_dir : nil
      configured || "out/"
    end
  end
end
