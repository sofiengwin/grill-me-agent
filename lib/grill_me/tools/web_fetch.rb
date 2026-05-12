require "faraday"
require "faraday/follow_redirects"
require "json"
require "langchain"
require "nokogiri"

module GrillMe
  module Tools
    # Langchain tool that fetches an arbitrary URL, parses the HTML with
    # Nokogiri, and returns a `{ url, title, text }` payload with the
    # readable body text truncated to ~12k chars. Network and parse
    # failures are surfaced as `{ "error": "..." }` payloads rather than
    # raising, so the agent loop can recover and try a different URL.
    class WebFetch
      extend Langchain::ToolDefinition

      MAX_CONTENT_CHARS = 12_000
      TIMEOUT_SECONDS = 30
      MAX_REDIRECTS = 5

      # Override the auto-derived snake_case class name so the LLM sees
      # the friendlier tool surface "web_fetch__fetch" rather than the
      # namespaced "grill_me_tools_web_fetch__fetch".
      def self.tool_name
        "web_fetch"
      end

      define_function :fetch,
                      description: "Fetch a URL and return its title plus readable text " \
                                   "content. Use this after web_search to read the contents " \
                                   "of a promising result page." do
        property :url, type: "string",
                       description: "Absolute http(s) URL to fetch (URI).",
                       required: true
      end

      def initialize(connection: nil, cache: nil, trace: nil, tag: nil)
        @connection = connection || default_connection
        @cache = cache
        @trace = trace
        @tag = tag
      end

      def fetch(url:)
        @trace&.event(type: "tool_call", tag: @tag,
                      data: { tool: self.class.tool_name, args: { url: url } })
        from_cache = true
        t0 = Time.now
        data = if @cache
          @cache.fetch(self.class.tool_name, { url: url }) do
            from_cache = false
            do_fetch(url)
          end
        else
          from_cache = false
          do_fetch(url)
        end
        latency_ms = ((Time.now - t0) * 1000).round
        @trace&.event(type: "tool_result", tag: @tag,
                      data: { tool: self.class.tool_name, result: data },
                      latency_ms: latency_ms, cached: from_cache)
        tool_response(content: JSON.generate(data))
      end

      private

      def do_fetch(url)
        response = @connection.get(url)

        unless response.success?
          return error_payload("http_#{response.status}", url)
        end

        title, text = parse_html(response.body.to_s)
        truncated_text, was_truncated = truncate(text)
        text_payload = was_truncated ? "#{truncated_text}\n[...truncated]" : truncated_text

        {
          "url" => url,
          "title" => title,
          "text" => text_payload
        }
      rescue Faraday::TimeoutError => e
        error_payload("timeout", url, e.message)
      rescue Faraday::ConnectionFailed => e
        error_payload("connection_failed", url, e.message)
      rescue Faraday::Error => e
        error_payload("faraday_error", url, e.message)
      rescue StandardError => e
        error_payload("parse_error", url, e.message)
      end

      def default_connection
        Faraday.new do |f|
          f.response :follow_redirects, limit: MAX_REDIRECTS
          f.options.timeout = TIMEOUT_SECONDS
          f.options.open_timeout = TIMEOUT_SECONDS
          f.adapter Faraday.default_adapter
        end
      end

      # Parses the HTML and returns `[title, text]`. The title prefers the
      # document `<title>` and falls back to the first `<h1>`, defaulting
      # to an empty string when neither is present. The text is the visible
      # body content with `<script>` and `<style>` removed and whitespace
      # collapsed to single spaces so the LLM gets compact, readable prose.
      def parse_html(html)
        doc = Nokogiri::HTML(html)
        [extract_title(doc), extract_text(doc)]
      end

      def extract_title(doc)
        title = doc.at_css("title")&.text&.strip
        return title if title && !title.empty?

        h1 = doc.at_css("h1")&.text&.strip
        h1 || ""
      end

      def extract_text(doc)
        doc.css("script, style, noscript").remove
        body = doc.at_css("body") || doc
        body.text.gsub(/\s+/, " ").strip
      end

      def truncate(str, limit = MAX_CONTENT_CHARS)
        return [str, false] if str.length <= limit

        [str[0, limit], true]
      end

      def error_payload(code, url, message = nil)
        payload = { "error" => code, "url" => url }
        payload["message"] = message if message
        payload
      end
    end
  end
end
