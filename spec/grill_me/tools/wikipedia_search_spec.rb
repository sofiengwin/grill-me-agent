require "spec_helper"

RSpec.describe GrillMe::Tools::WikipediaSearch do
  let(:tool) { described_class.new }
  let(:api_url) { %r{https://en\.wikipedia\.org/w/api\.php} }

  def opensearch_body(titles, snippets, urls, query: "henry")
    JSON.generate([query, titles, snippets, urls])
  end

  describe "#search" do
    it "returns the parsed results as { title, snippet, url } objects" do
      body = opensearch_body(
        ["Thierry Henry", "Henry VIII"],
        ["French footballer", "King of England"],
        ["https://en.wikipedia.org/wiki/Thierry_Henry", "https://en.wikipedia.org/wiki/Henry_VIII"]
      )
      stub_request(:get, api_url).to_return(status: 200, body: body)

      response = tool.search(query: "henry")
      results = JSON.parse(response.content)

      expect(results).to eq([
        {
          "title" => "Thierry Henry",
          "snippet" => "French footballer",
          "url" => "https://en.wikipedia.org/wiki/Thierry_Henry"
        },
        {
          "title" => "Henry VIII",
          "snippet" => "King of England",
          "url" => "https://en.wikipedia.org/wiki/Henry_VIII"
        }
      ])
    end

    it "requests opensearch with limit=5 and the supplied query" do
      stub_request(:get, api_url)
        .to_return(status: 200, body: opensearch_body([], [], []))

      tool.search(query: "thierry henry")

      expect(WebMock).to have_requested(:get, api_url).with(query: hash_including(
        "action" => "opensearch",
        "format" => "json",
        "limit" => described_class::LIMIT.to_s,
        "search" => "thierry henry"
      ))
    end

    it "returns at most 5 results matching the LIMIT constant" do
      titles = (1..5).map { |i| "Title #{i}" }
      snippets = (1..5).map { |i| "Snippet #{i}" }
      urls = (1..5).map { |i| "https://en.wikipedia.org/wiki/Title_#{i}" }
      stub_request(:get, api_url)
        .to_return(status: 200, body: opensearch_body(titles, snippets, urls))

      results = JSON.parse(tool.search(query: "anything").content)

      expect(results.length).to eq(5)
      expect(results.length).to be <= described_class::LIMIT
    end

    it "fills missing snippets and urls with empty strings" do
      body = JSON.generate(["q", ["Only Title"], [], []])
      stub_request(:get, api_url).to_return(status: 200, body: body)

      results = JSON.parse(tool.search(query: "q").content)

      expect(results).to eq([{ "title" => "Only Title", "snippet" => "", "url" => "" }])
    end

    it "returns an empty array when MediaWiki yields no matches" do
      stub_request(:get, api_url)
        .to_return(status: 200, body: opensearch_body([], [], []))

      results = JSON.parse(tool.search(query: "no-such-thing").content)

      expect(results).to eq([])
    end

    it "returns an HTTP error payload on non-2xx responses" do
      stub_request(:get, api_url).to_return(status: 500, body: "boom")

      payload = JSON.parse(tool.search(query: "henry").content)

      expect(payload).to eq("error" => "http 500", "query" => "henry")
    end

    it "wraps JSON parse errors as an error payload" do
      stub_request(:get, api_url).to_return(status: 200, body: "not-json{")

      payload = JSON.parse(tool.search(query: "henry").content)

      expect(payload["error"]).to be_a(String)
      expect(payload["error"]).not_to be_empty
      expect(payload["query"]).to eq("henry")
    end

    it "wraps Faraday network errors as an error payload" do
      stub_request(:get, api_url).to_raise(Faraday::ConnectionFailed.new("connection refused"))

      payload = JSON.parse(tool.search(query: "henry").content)

      expect(payload["error"]).to include("connection refused")
      expect(payload["query"]).to eq("henry")
    end
  end
end
