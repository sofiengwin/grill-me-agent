require "spec_helper"

RSpec.describe GrillMe::Runner do
  let(:env) { { "OPENAI_API_KEY" => "sk-test", "BRAVE_SEARCH_API_KEY" => "brv" } }
  let(:config) { GrillMe::Config.new(env: env) }
  let(:mock_logger) { instance_double(::Logger, info: nil, warn: nil) }
  let(:mock_llm) do
    llm = Langchain::LLM::OpenAI.new(api_key: "sk-test")
    allow(llm).to receive(:chat)
    llm
  end
  let(:mock_window) { GrillMe::Window.new(as_of: Date.new(2026, 5, 8), years: 20) }
  let(:mock_assembler) { instance_double(GrillMe::Assembler) }
  let(:mock_output) { instance_double(GrillMe::Output) }
  let(:club) { GrillMe::Input.from_args(name: "Arsenal", country: "England") }
  let(:artifact) { { "schema_version" => "1.0", "club" => { "name" => "Arsenal" } } }
  let(:roster_agent_double) { instance_double(GrillMe::Agents::RosterAgent) }

  let(:runner) do
    described_class.new(
      config: config, logger: mock_logger, llm: mock_llm, window: mock_window,
      assembler: mock_assembler, output: mock_output
    )
  end

  before do
    allow(GrillMe::Agents::RosterAgent).to receive(:new).and_return(roster_agent_double)
    allow(mock_assembler).to receive(:build).and_return(artifact)
    allow(mock_output).to receive(:write).and_return("out/arsenal-england.json")
    allow(GrillMe::Schema).to receive(:validate_club!)
  end

  def stub_player_agent(&block)
    allow(GrillMe::Agents::PlayerAgent).to receive(:new) do |**_kw|
      agent = instance_double(GrillMe::Agents::PlayerAgent)
      allow(agent).to receive(:run, &block)
      agent
    end
  end

  def stub_roster(names)
    roster = names.map { |n| { "name" => n } }
    allow(roster_agent_double).to receive(:run).and_return(roster)
    roster
  end

  def player_record(name)
    { "name" => name, "club_name" => "Arsenal", "club_country" => "England", "appearances" => 100 }
  end

  it "runs player agents concurrently" do
    stub_roster(%w[A B C D])
    stub_player_agent do |player_name:, **|
      sleep 0.1
      player_record(player_name)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    runner.run(club: club)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(GrillMe::Agents::PlayerAgent).to have_received(:new).exactly(4).times
    expect(elapsed).to be < 0.4
  end

  it "respects the concurrency limit" do
    config.instance_variable_set(:@concurrency, 2)
    stub_roster(%w[A B C D E F])

    mutex = Mutex.new
    active = 0
    max_active = 0

    stub_player_agent do |player_name:, **|
      mutex.synchronize do
        active += 1
        max_active = active if active > max_active
      end
      sleep 0.1
      mutex.synchronize { active -= 1 }
      player_record(player_name)
    end

    runner.run(club: club)

    expect(max_active).to be <= 2
    expect(max_active).to be >= 1
  end

  it "times out and marks pending as failures" do
    config.instance_variable_set(:@per_club_timeout_s, 1)
    stub_roster(%w[Fast Slow1 Slow2])

    stop_event = Concurrent::Event.new
    allow(GrillMe::Agents::PlayerAgent).to receive(:new) do |**_kw|
      agent = instance_double(GrillMe::Agents::PlayerAgent)
      allow(agent).to receive(:run) do |player_name:, **|
        stop_event.wait(10) unless player_name == "Fast"
        player_record(player_name)
      end
      agent
    end

    pool_spy = []
    allow(Concurrent::FixedThreadPool).to receive(:new).and_wrap_original do |orig, *a, **k|
      pool = orig.call(*a, **k)
      pool.define_singleton_method(:wait_for_termination) { |_t = nil| false }
      pool_spy << pool
      pool
    end

    begin
      runner.run(club: club)
    ensure
      stop_event.set
    end

    expect(mock_assembler).to have_received(:build) do |club:, players:, failed_players:|
      timed_out = failed_players.select { |f| f["reason"] == "per_club_timeout_reached" }
      expect(timed_out.map { |f| f["name"] }).to contain_exactly("Slow1", "Slow2")
    end
    expect(pool_spy.first.shuttingdown? || pool_spy.first.shutdown?).to be true
  end

  it "collects successful records and failures" do
    stub_roster(%w[Good MaxIter SchemaBad])

    allow(GrillMe::Agents::PlayerAgent).to receive(:new) do |**_kw|
      agent = instance_double(GrillMe::Agents::PlayerAgent)
      allow(agent).to receive(:run) do |player_name:, **|
        case player_name
        when "Good" then player_record(player_name)
        when "MaxIter" then raise GrillMe::Agents::PlayerAgent::MaxIterationsError, "max_iterations_reached (8)"
        when "SchemaBad" then raise GrillMe::Agents::PlayerAgent::SchemaValidationError, "schema invalid"
        end
      end
      agent
    end

    runner.run(club: club)

    expect(mock_assembler).to have_received(:build) do |club:, players:, failed_players:|
      expect(players.map { |p| p["name"] }).to eq(["Good"])
      expect(failed_players).to contain_exactly(
        { "name" => "MaxIter", "reason" => "max_iterations_reached (8)" },
        { "name" => "SchemaBad", "reason" => "schema invalid" }
      )
    end
  end

  it "passes results to assembler and output" do
    stub_roster(["Henry"])
    stub_player_agent { |player_name:, **| player_record(player_name) }

    result = runner.run(club: club)

    expect(mock_assembler).to have_received(:build).with(
      club: club,
      players: [player_record("Henry")],
      failed_players: []
    )
    expect(mock_output).to have_received(:write).with(
      artifact: artifact, destination: "out/"
    )
    expect(result).to eq("out/arsenal-england.json")
  end

  it "uses per-agent log tags" do
    stub_roster(["Thierry Henry"])
    stub_player_agent { |player_name:, **| player_record(player_name) }

    runner.run(club: club)

    expect(mock_logger).to have_received(:info).with(/\[Arsenal\/player:Thierry Henry\] starting/)
    expect(mock_logger).to have_received(:info).with(/\[Arsenal\/player:Thierry Henry\] success/)
  end

  it "delegates roster agent errors" do
    allow(roster_agent_double).to receive(:run)
      .and_raise(GrillMe::Agents::RosterAgent::MaxIterationsError, "max_iterations_reached (15)")

    expect { runner.run(club: club) }
      .to raise_error(GrillMe::Agents::RosterAgent::MaxIterationsError, /max_iterations_reached/)

    expect(mock_assembler).not_to have_received(:build)
    expect(mock_output).not_to have_received(:write)
  end
end
