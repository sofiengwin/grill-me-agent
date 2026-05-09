require "spec_helper"

RSpec.describe GrillMe::Llm do
  describe ".build" do
    it "returns a Langchain OpenAI LLM with the configured chat model and temperature" do
      llm = described_class.build(provider: :openai, model: "gpt-4o-mini", temperature: 0.0, api_key: "sk-test")

      expect(llm).to be_a(Langchain::LLM::OpenAI)
      expect(llm.defaults[:chat_model]).to eq("gpt-4o-mini")
      expect(llm.defaults[:temperature]).to eq(0.0)
    end

    it "raises UnknownProviderError for unsupported providers" do
      expect do
        described_class.build(provider: :anthropic, api_key: "x")
      end.to raise_error(GrillMe::Llm::UnknownProviderError, /anthropic/)
    end

    it "raises MissingApiKeyError when no API key is available" do
      stub_const("ENV", ENV.to_h.merge("OPENAI_API_KEY" => nil))
      expect do
        described_class.build(provider: :openai, api_key: nil)
      end.to raise_error(GrillMe::Llm::MissingApiKeyError)
    end

    it "exposes a uniform chat interface accepting messages and tools" do
      llm = described_class.build(api_key: "sk-test")
      expect(llm).to respond_to(:chat)
    end
  end
end
