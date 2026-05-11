require "spec_helper"

RSpec.describe GrillMe::Tools::WikidataSparql do
  let(:tool) { described_class.new }
  let(:endpoint) { %r{https://query\.wikidata\.org/sparql} }

  def sparql_body(bindings)
    JSON.generate(
      "head" => { "vars" => bindings.flat_map(&:keys).uniq },
      "results" => { "bindings" => bindings }
    )
  end

  def stub_sparql(body, status: 200)
    stub_request(:post, endpoint)
      .to_return(
        status: status,
        body: body,
        headers: { "Content-Type" => "application/sparql-results+json" }
      )
  end

  describe "#query" do
    it "POSTs the SPARQL query and parses bindings into flat row hashes" do
      bindings = [
        {
          "player" => { "type" => "uri", "value" => "http://www.wikidata.org/entity/Q42389" },
          "playerLabel" => { "type" => "literal", "value" => "Thierry Henry" }
        },
        {
          "player" => { "type" => "uri", "value" => "http://www.wikidata.org/entity/Q615" },
          "playerLabel" => { "type" => "literal", "value" => "Lionel Messi" }
        }
      ]
      stub_sparql(sparql_body(bindings))

      payload = JSON.parse(tool.query(sparql: "SELECT ?player ?playerLabel WHERE {} LIMIT 10").content)

      expect(payload["row_count"]).to eq(2)
      expect(payload["truncated"]).to eq(false)
      expect(payload["rows"]).to eq([
        { "player" => "http://www.wikidata.org/entity/Q42389", "playerLabel" => "Thierry Henry" },
        { "player" => "http://www.wikidata.org/entity/Q615", "playerLabel" => "Lionel Messi" }
      ])
    end

    it "sends the SPARQL string url-encoded with the JSON Accept header" do
      stub_sparql(sparql_body([]))
      sparql = "SELECT ?p WHERE {} LIMIT 1"

      tool.query(sparql: sparql)

      expect(WebMock).to have_requested(:post, endpoint).with { |req|
        req.headers["Accept"] == "application/sparql-results+json" &&
          req.headers["Content-Type"] == "application/x-www-form-urlencoded" &&
          req.body == URI.encode_www_form(query: sparql)
      }
    end

    it "drops bindings that are missing a value" do
      bindings = [
        {
          "player" => { "type" => "uri", "value" => "http://www.wikidata.org/entity/Q1" },
          "missing" => { "type" => "literal" }
        }
      ]
      stub_sparql(sparql_body(bindings))

      payload = JSON.parse(tool.query(sparql: "SELECT ?player WHERE {} LIMIT 1").content)

      expect(payload["rows"]).to eq([{ "player" => "http://www.wikidata.org/entity/Q1" }])
    end

    it "caps results at MAX_ROWS and flags truncated=true" do
      oversized = (1..600).map do |i|
        { "p" => { "type" => "uri", "value" => "http://www.wikidata.org/entity/Q#{i}" } }
      end
      stub_sparql(sparql_body(oversized))

      payload = JSON.parse(tool.query(sparql: "SELECT ?p WHERE {} LIMIT 600").content)

      expect(payload["rows"].length).to eq(described_class::MAX_ROWS)
      expect(payload["row_count"]).to eq(described_class::MAX_ROWS)
      expect(payload["truncated"]).to eq(true)
      expect(payload["rows"].first).to eq("p" => "http://www.wikidata.org/entity/Q1")
      expect(payload["rows"].last).to eq("p" => "http://www.wikidata.org/entity/Q500")
    end

    it "returns an error payload on non-2xx responses with a snippet of the body" do
      stub_sparql("Internal Server Error", status: 500)

      payload = JSON.parse(tool.query(sparql: "SELECT ?x WHERE {}").content)

      expect(payload["error"]).to eq("HTTP 500")
      expect(payload["detail"]).to eq("Internal Server Error")
    end

    it "wraps timeout errors as a timeout payload" do
      stub_request(:post, endpoint).to_raise(Faraday::TimeoutError.new("execution expired"))

      payload = JSON.parse(tool.query(sparql: "SELECT ?x WHERE {}").content)

      expect(payload["error"]).to eq("timeout")
      expect(payload["detail"]).to include("execution expired")
    end

    it "wraps connection failures as a connection_failed payload" do
      stub_request(:post, endpoint).to_raise(Faraday::ConnectionFailed.new("connection refused"))

      payload = JSON.parse(tool.query(sparql: "SELECT ?x WHERE {}").content)

      expect(payload["error"]).to eq("connection_failed")
      expect(payload["detail"]).to include("connection refused")
    end

    it "wraps invalid JSON responses as an invalid_response payload" do
      stub_sparql("not-json{")

      payload = JSON.parse(tool.query(sparql: "SELECT ?x WHERE {}").content)

      expect(payload["error"]).to eq("invalid_response")
      expect(payload["detail"]).to be_a(String)
    end
  end
end
