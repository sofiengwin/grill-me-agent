require "concurrent"
require "fileutils"

module GrillMe
  # Orchestrates the per-club research pipeline: runs the RosterAgent to
  # discover players, fans the player records out across a fixed thread
  # pool of PlayerAgent runs, enforces a per-club wall-clock timeout, and
  # hands the assembled artifact to the Output writer.
  class Runner
    def initialize(config:, logger:, llm:, window:, assembler:, output:, cache: nil, trace: nil)
      @config = config
      @logger = logger
      @llm = llm
      @window = window
      @assembler = assembler
      @output = output
      @cache = cache
      @trace = trace
    end

    def run(club:)
      slug = Output.slug_for_club(name: club.name, country: club.country)
      trace_dir = ensure_trace_dir(slug: slug)

      roster = discover_roster(club: club, slug: slug, trace_dir: trace_dir)

      pool = Concurrent::FixedThreadPool.new(@config.concurrency)
      futures = roster.map do |player|
        submit_player(pool: pool, club: club, player: player, slug: slug, trace_dir: trace_dir)
      end

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

    def discover_roster(club:, slug:, trace_dir:)
      agent_trace = build_agent_trace(trace_dir, "roster.jsonl")
      tag = "#{slug}/roster"
      roster_agent = Agents::RosterAgent.new(llm: @llm, cache: @cache, trace: agent_trace, tag: tag)
      roster = roster_agent.run(club_name: club.name, club_country: club.country)
      @logger.info("roster discovered club=#{club.name.inspect} size=#{roster.size}")
      roster
    ensure
      agent_trace&.close
    end

    def submit_player(pool:, club:, player:, slug:, trace_dir:)
      player_name = player["name"]
      player_slug = Output.transliterate(player_name)
      logger = @logger
      llm = @llm
      cache = @cache
      runner = self
      Concurrent::Future.execute(executor: pool) do
        log_tag = "#{club.name}/player:#{player_name}"
        trace_tag = "#{slug}/player:#{player_slug}"
        agent_trace = runner.send(:build_agent_trace, trace_dir, "player-#{player_slug}.jsonl")
        logger.info("[#{log_tag}] starting player agent")
        agent = Agents::PlayerAgent.new(llm: llm, cache: cache, trace: agent_trace, tag: trace_tag)
        begin
          record = agent.run(
            player_name: player_name,
            club_name: club.name,
            club_country: club.country
          )
          logger.info("[#{log_tag}] success")
          { type: :success, record: record }
        rescue Agents::PlayerAgent::AgentError => e
          logger.warn("[#{log_tag}] failed: #{e.message}")
          { type: :failure, name: player_name, reason: e.message }
        ensure
          agent_trace&.close
        end
      end
    end

    # Build a per-agent Trace that shares the base trace's sinks (typically
    # an StderrSink) and adds a fresh JsonlSink writing to the per-agent
    # transcript file. Returns nil when no base trace is configured so the
    # agent's emit calls become no-ops.
    def build_agent_trace(trace_dir, filename)
      return nil if @trace.nil? || trace_dir.nil?

      path = File.join(trace_dir, filename)
      sinks = Array(@trace.sinks) + [GrillMe::JsonlSink.new(path)]
      GrillMe::Trace.new(level: @trace.level, sinks: sinks)
    end

    def ensure_trace_dir(slug:)
      return nil if @trace.nil?

      base = trace_base_dir
      return nil if base.nil?

      dir = File.join(base, slug, "_traces")
      FileUtils.mkdir_p(dir)
      dir
    end

    def trace_base_dir
      dest = output_destination
      return nil if dest.nil? || dest.empty?

      if dest.end_with?("/") || (File.exist?(dest) && File.directory?(dest))
        dest
      else
        File.dirname(dest)
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
