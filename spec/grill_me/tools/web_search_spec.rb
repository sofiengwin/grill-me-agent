require "spec_helper"

RSpec.describe GrillMe::Tools::WebSearch do
  let(:api_key) { "test-key" }
  let(:tool) { described_class.new }
  let(:api_url) { %r{https://api\.search\.brave\.com/res/v1/web/search} }

  before do
    described_class.last_call_time = nil
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BRAVE_SEARCH_API_KEY").and_return(api_key)
  end

  def brave_body(results)
    JSON.generate("web" => { "results" => results })
  end

  describe "#search" do
    it "returns parsed results as { title, url, snippet } objects" do
      stub_request(:get, api_url).to_return(
        status: 200,
        body: brave_body([
          { "title" => "Thierry Henry", "url" => "https://example.com/henry",
            "description" => "French footballer" },
          { "title" => "Henry VIII", "url" => "https://example.com/h8",
            "description" => "King of England" }
        ])
      )

      results = JSON.parse(tool.search(query: "henry").content)

      expect(results).to eq([
        { "title" => "Thierry Henry", "url" => "https://example.com/henry",
          "snippet" => "French footballer" },
        { "title" => "Henry VIII", "url" => "https://example.com/h8",
          "snippet" => "King of England" }
      ])
    end

    it "requests search with default count=5 and the supplied query and auth header" do
      stub_request(:get, api_url).to_return(status: 200, body: brave_body([]))

      tool.search(query: "thierry henry")

      expect(WebMock).to have_requested(:get, api_url).with(
        query: hash_including("q" => "thierry henry", "count" => "5"),
        headers: { "X-Subscription-Token" => api_key, "Accept" => "application/json" }
      )
    end

    it "passes a custom max_results value through as the count query param" do
      stub_request(:get, api_url).to_return(status: 200, body: brave_body([]))

      tool.search(query: "anything", max_results: 10)

      expect(WebMock).to have_requested(:get, api_url)
        .with(query: hash_including("q" => "anything", "count" => "10"))
    end

    it "returns an empty array when Brave yields no results" do
      stub_request(:get, api_url).to_return(status: 200, body: brave_body([]))

      results = JSON.parse(tool.search(query: "no-such-thing").content)

      expect(results).to eq([])
    end

    [401, 403, 500].each do |status|
      it "returns an HTTP error payload on #{status} responses" do
        stub_request(:get, api_url).to_return(status: status, body: "boom")

        payload = JSON.parse(tool.search(query: "henry").content)

        expect(payload["error"]).to eq("http_#{status}")
        expect(payload["detail"]).to eq("boom")
      end
    end

    it "wraps Faraday connection errors as a connection_failed payload" do
      stub_request(:get, api_url).to_raise(Faraday::ConnectionFailed.new("connection refused"))

      payload = JSON.parse(tool.search(query: "henry").content)

      expect(payload["error"]).to eq("connection_failed")
      expect(payload["detail"]).to include("connection refused")
    end

    it "wraps JSON parse errors as an invalid_response payload" do
      stub_request(:get, api_url).to_return(status: 200, body: "not-json{")

      payload = JSON.parse(tool.search(query: "henry").content)

      expect(payload["error"]).to eq("invalid_response")
      expect(payload["detail"]).to be_a(String)
      expect(payload["detail"]).not_to be_empty
    end

    context "when no API key is configured" do
      it "returns a missing_api_key payload without making a request" do
        allow(ENV).to receive(:[]).with("BRAVE_SEARCH_API_KEY").and_return(nil)
        stub = stub_request(:get, api_url)
        keyless_tool = described_class.new

        payload = JSON.parse(keyless_tool.search(query: "henry").content)

        expect(payload["error"]).to eq("missing_api_key")
        expect(stub).not_to have_been_requested
      end
    end
  end

  describe "rate limiting" do
    let(:tool) { described_class.new(qps: 1.0) }

    before do
      stub_request(:get, api_url).to_return(status: 200, body: brave_body([]))
      allow(Process).to receive(:clock_gettime).and_call_original
    end

    it "does not sleep when more than 1/qps seconds have elapsed since the last call" do
      described_class.last_call_time = 100.0
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC).and_return(101.5)

      expect(tool).not_to receive(:sleep)

      tool.search(query: "henry")
    end

    it "sleeps for the remaining interval when called within 1/qps seconds of the last call" do
      described_class.last_call_time = 100.0
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC).and_return(100.2)

      expect(tool).to receive(:sleep).with(a_value_within(0.001).of(0.8))

      tool.search(query: "henry")
    end

    it "skips throttling entirely when qps is zero or nil" do
      unthrottled = described_class.new(qps: 0)
      described_class.last_call_time = 100.0
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC).and_return(100.0001)

      expect(unthrottled).not_to receive(:sleep)

      unthrottled.search(query: "henry")
    end
  end
end
