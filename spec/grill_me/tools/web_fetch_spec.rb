require "spec_helper"

RSpec.describe GrillMe::Tools::WebFetch do
  let(:tool) { described_class.new }
  let(:url) { "https://example.com/article" }

  describe "#fetch" do
    it "returns {url, title, text} for a valid HTML page" do
      html = <<~HTML
        <html>
          <head><title>Test Page</title></head>
          <body>
            <h1>Heading</h1>
            <p>Hello world, this is some readable body text.</p>
            <script>var x = 1;</script>
            <style>body { color: red; }</style>
          </body>
        </html>
      HTML
      stub_request(:get, url).to_return(status: 200, body: html, headers: { "Content-Type" => "text/html" })

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["url"]).to eq(url)
      expect(payload["title"]).to eq("Test Page")
      expect(payload["text"]).to include("Hello world, this is some readable body text.")
      expect(payload["text"]).to include("Heading")
      expect(payload["text"]).not_to include("var x = 1;")
      expect(payload["text"]).not_to include("color: red")
    end

    it "extracts title from h1 when title tag is missing" do
      html = "<html><body><h1>Main Heading</h1><p>Body text.</p></body></html>"
      stub_request(:get, url).to_return(status: 200, body: html)

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["title"]).to eq("Main Heading")
    end

    it "truncates text at MAX_CONTENT_CHARS" do
      big_body = "x" * (described_class::MAX_CONTENT_CHARS + 5_000)
      html = "<html><head><title>Big</title></head><body>#{big_body}</body></html>"
      stub_request(:get, url).to_return(status: 200, body: html)

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["text"]).to end_with("[...truncated]")
      expect(payload["text"].length).to be <= described_class::MAX_CONTENT_CHARS + "\n[...truncated]".length
    end

    it "returns an HTTP error payload on 404 responses" do
      stub_request(:get, url).to_return(status: 404, body: "not found")

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload).to eq("error" => "http_404", "url" => url)
    end

    it "returns an HTTP error payload on 500 responses" do
      stub_request(:get, url).to_return(status: 500, body: "server error")

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload).to eq("error" => "http_500", "url" => url)
    end

    it "wraps timeout errors as an error payload" do
      stub_request(:get, url).to_raise(Faraday::TimeoutError.new("execution expired"))

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["error"]).to eq("timeout")
      expect(payload["url"]).to eq(url)
      expect(payload["message"]).to include("execution expired")
    end

    it "handles malformed HTML gracefully" do
      html = "<html><head><title>Broken</head><body><p>Unclosed paragraph<div>nested<span>text"
      stub_request(:get, url).to_return(status: 200, body: html)

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["title"]).to eq("Broken")
      expect(payload["text"]).to include("Unclosed paragraph")
      expect(payload["text"]).to include("nested")
      expect(payload["text"]).to include("text")
    end

    it "follows redirects to the final page" do
      final_url = "https://example.com/final"
      stub_request(:get, url)
        .to_return(status: 301, headers: { "Location" => final_url })
      stub_request(:get, final_url)
        .to_return(status: 200, body: "<html><head><title>Final</title></head><body>Final body</body></html>")

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["title"]).to eq("Final")
      expect(payload["text"]).to include("Final body")
    end

    it "returns empty text for an empty body" do
      stub_request(:get, url).to_return(status: 200, body: "")

      payload = JSON.parse(tool.fetch(url: url).content)

      expect(payload["url"]).to eq(url)
      expect(payload["title"]).to eq("")
      expect(payload["text"]).to eq("")
    end
  end
end
