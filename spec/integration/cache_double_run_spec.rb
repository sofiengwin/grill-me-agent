require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "double-run caching", type: :integration do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:cache) { GrillMe::Cache.new(base_dir: tmp_dir) }

  after { FileUtils.rm_rf(tmp_dir) }

  context "LLM responses are cached and reused" do
    let(:replay_llm) { LlmReplay.stub_llm("player_agent/henry_arsenal") }
    let(:messages) { [{ role: "user", content: "Tell me about Thierry Henry" }] }

    before do
      allow(Langchain::LLM::OpenAI).to receive(:new).and_return(replay_llm)
    end

    it "serves the second chat call from cache without invoking the underlying LLM again" do
      llm = GrillMe::Llm.build(cache: cache, temperature: 0.0, api_key: "sk-test")

      chat_calls = 0
      original_chat = replay_llm.method(:chat)
      replay_llm.define_singleton_method(:chat) do |**kwargs|
        chat_calls += 1
        original_chat.call(**kwargs)
      end

      first = llm.chat(messages: messages)
      second = llm.chat(messages: messages)

      expect(chat_calls).to eq(1)
      expect(first.raw_response).to eq(second.raw_response)
      expect(Dir.glob(File.join(tmp_dir, "llm", "*.json"))).not_to be_empty
    end
  end

  context "tool results are cached and reused" do
    let(:fixture_path) { File.expand_path("../fixtures/wikipedia/thierry_henry.json", __dir__) }
    let(:fixture_body) { File.read(fixture_path) }
    let(:wiki_url_pattern) { %r{en\.wikipedia\.org.*?/w/api\.php} }

    before do
      stub_request(:get, wiki_url_pattern)
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
    end

    it "serves the second tool fetch from cache without issuing new HTTP requests" do
      tool = GrillMe::Tools::WikipediaPage.new(cache: cache)

      first = tool.fetch(title: "Thierry Henry")
      requests_after_first = http_request_count(wiki_url_pattern)
      expect(requests_after_first).to be > 0

      second = tool.fetch(title: "Thierry Henry")
      requests_after_second = http_request_count(wiki_url_pattern)

      expect(requests_after_second).to eq(requests_after_first)
      expect(JSON.parse(first.content)).to eq(JSON.parse(second.content))
      expect(Dir.glob(File.join(tmp_dir, "tools", "*.json"))).not_to be_empty
    end

    def http_request_count(pattern)
      WebMock::RequestRegistry.instance.requested_signatures.hash.sum do |signature, count|
        signature.uri.to_s.match?(pattern) ? count : 0
      end
    end
  end
end
