require "spec_helper"

RSpec.describe GrillMe::Agents::PlayerAgent do
  let(:fixture_body) do
    File.read(File.expand_path("../../fixtures/wikipedia/thierry_henry.json", __dir__))
  end

  before do
    stub_request(:get, %r{https://en\.wikipedia\.org/w/api\.php})
      .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
  end

  describe "#run end-to-end against committed fixtures" do
    it "produces a schema-valid player record from one tool call" do
      llm = LlmReplay.stub_llm("player_agent/henry_arsenal")
      agent = described_class.new(llm: llm)

      record = agent.run(player_name: "Thierry Henry", club_name: "Arsenal", club_country: "England")

      expect(GrillMe::Schema.valid_player?(record)).to be true
      expect(record["name"]).to eq("Thierry Henry")
      expect(record["club_name"]).to eq("Arsenal")
      expect(record["start"]).to eq("1999-08")
      expect(record["end"]).to eq("2007-06")
      expect(record["appearances"]).to eq(254)
      expect(record["confidence"]).to eq("high")
      expect(record["sources"]).to include("https://en.wikipedia.org/wiki/Thierry_Henry")
    end

    it "exposes the prompt version after running" do
      llm = LlmReplay.stub_llm("player_agent/henry_arsenal")
      agent = described_class.new(llm: llm)
      agent.run(player_name: "Thierry Henry", club_name: "Arsenal")

      expect(agent.prompt_version).to eq("1")
    end

    it "issues a corrective retry when the model returns an invalid record" do
      llm = LlmReplay.stub_llm("player_agent/henry_arsenal_with_retry")
      agent = described_class.new(llm: llm)

      record = agent.run(player_name: "Thierry Henry", club_name: "Arsenal", club_country: "England")

      expect(GrillMe::Schema.valid_player?(record)).to be true
      expect(record["confidence"]).to eq("high")
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
              "function" => { "name" => "wikipedia_page__fetch", "arguments" => "{\"title\":\"Thierry Henry\"}" }
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
        agent.run(player_name: "Thierry Henry", club_name: "Arsenal")
      end.to raise_error(GrillMe::Agents::PlayerAgent::MaxIterationsError)
    end
  end

  describe "schema-validation retry exhaustion" do
    it "raises SchemaValidationError after exhausting retries" do
      bad = {
        "id" => "x",
        "model" => "gpt-4o-mini",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => "{\"name\":\"X\",\"club_name\":\"Y\"}"
          }
        }],
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2 }
      }

      llm = Langchain::LLM::OpenAI.new(api_key: "sk-x")
      allow(llm).to receive(:chat).and_return(Langchain::LLM::OpenAIResponse.new(bad))

      agent = described_class.new(llm: llm)
      expect do
        agent.run(player_name: "X", club_name: "Y")
      end.to raise_error(GrillMe::Agents::PlayerAgent::SchemaValidationError)
    end
  end
end
