require "spec_helper"

RSpec.describe GrillMe::Agents::RosterAgent do
  let(:fixture_body) do
    File.read(File.expand_path("../../fixtures/wikipedia/thierry_henry.json", __dir__))
  end

  before do
    stub_request(:get, %r{https://en\.wikipedia\.org/w/api\.php})
      .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
  end

  describe "#run end-to-end against committed fixtures" do
    it "produces a roster array of player hashes" do
      llm = LlmReplay.stub_llm("roster_agent/arsenal_roster")
      agent = described_class.new(llm: llm)

      roster = agent.run(club_name: "Arsenal", club_country: "England")

      expect(roster).to be_an(Array)
      expect(roster.size).to eq(3)
      expect(roster.map { |p| p["name"] }).to eq(["Thierry Henry", "Dennis Bergkamp", "Patrick Vieira"])
      expect(roster.map { |p| p["wikipedia_url"] }).to eq([
        "https://en.wikipedia.org/wiki/Thierry_Henry",
        "https://en.wikipedia.org/wiki/Dennis_Bergkamp",
        "https://en.wikipedia.org/wiki/Patrick_Vieira"
      ])
    end

    it "exposes the prompt version after running" do
      llm = LlmReplay.stub_llm("roster_agent/arsenal_roster")
      agent = described_class.new(llm: llm)
      agent.run(club_name: "Arsenal", club_country: "England")

      expect(agent.prompt_version).to eq("1")
    end
  end

  describe "iteration cap" do
    def tool_call_response
      {
        "id" => "x",
        "model" => "gpt-4o-mini",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [{
              "id" => "t1",
              "type" => "function",
              "function" => { "name" => "wikipedia_search__search", "arguments" => "{\"query\":\"Arsenal football club players\"}" }
            }]
          }
        }],
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }
    end

    it "raises MaxIterationsError after MAX_ITERATIONS LLM turns" do
      llm = Langchain::LLM::OpenAI.new(api_key: "sk-x")
      allow(llm).to receive(:chat).and_return(Langchain::LLM::OpenAIResponse.new(tool_call_response))

      agent = described_class.new(llm: llm)
      expect do
        agent.run(club_name: "Arsenal", club_country: "England")
      end.to raise_error(GrillMe::Agents::RosterAgent::MaxIterationsError)
    end
  end

  describe "invalid JSON" do
    it "raises InvalidJSONError when assistant returns non-JSON" do
      bad = {
        "id" => "x",
        "model" => "gpt-4o-mini",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => "Sorry, I cannot produce a roster right now."
          }
        }],
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }

      llm = Langchain::LLM::OpenAI.new(api_key: "sk-x")
      allow(llm).to receive(:chat).and_return(Langchain::LLM::OpenAIResponse.new(bad))

      agent = described_class.new(llm: llm)
      expect do
        agent.run(club_name: "Arsenal")
      end.to raise_error(GrillMe::Agents::RosterAgent::InvalidJSONError)
    end
  end

  describe "roster sanity cap" do
    it "caps roster at ROSTER_SANITY_CAP" do
      players = Array.new(260) do |i|
        { "name" => "Player #{i}", "wikidata_id" => nil, "wikipedia_url" => nil }
      end
      huge = {
        "id" => "x",
        "model" => "gpt-4o-mini",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => JSON.generate(players)
          }
        }],
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }

      llm = Langchain::LLM::OpenAI.new(api_key: "sk-x")
      allow(llm).to receive(:chat).and_return(Langchain::LLM::OpenAIResponse.new(huge))

      agent = described_class.new(llm: llm)
      roster = agent.run(club_name: "Arsenal")

      expect(roster.size).to eq(GrillMe::Agents::RosterAgent::ROSTER_SANITY_CAP)
      expect(roster.size).to eq(250)
      expect(roster.first["name"]).to eq("Player 0")
      expect(roster.last["name"]).to eq("Player 249")
    end
  end
end
