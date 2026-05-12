require "faraday"
require "json"
require "langchain"

module GrillMe
  module Tools
    # Langchain tool that wraps the Brave Search API. Given a free-form query
    # string it returns up to MAX_RESULTS matching pages as a JSON array of
    # `{ title, url, snippet }` objects so the agent can pick promising URLs
    # before fetching their contents with `WebFetch`.
    #
    # A class-level rate limiter throttles outbound calls to roughly `qps`
    # requests per second across all instances, since Brave's free tier caps
    # callers at ~1 QPS. Network and parse failures are surfaced as
    # `{ "error": "..." }` payloads rather than raising, so the agent loop
    # can recover and try a different query.
    class WebSearch
      extend Langchain::ToolDefinition

      API_URL = "https://api.search.brave.com/res/v1/web/search".freeze
      DEFAULT_MAX_RESULTS = 5
      MAX_RESULTS_CAP = 20
      TIMEOUT_SECONDS = 15

      @mutex = Mutex.new
      @last_call_time = nil

      class << self
        attr_accessor :last_call_time
        attr_reader :mutex
      end

      # Override the auto-derived snake_case class name so the LLM sees
      # the friendlier tool surface "web_search__search" rather than the
      # namespaced "grill_me_tools_web_search__search".
      def self.tool_name
        "web_search"
      end

      define_function :search,
                      description: "Search the web via Brave Search and return the top results " \
                                   "as { title, url, snippet } objects. Use this as a fallback " \
                                   "when Wikipedia/Wikidata don't have the information you need." do
        property :query, type: "string",
                         description: "Search query, e.g. a player name or phrase.",
                         required: true
        property :max_results, type: "integer",
                               description: "Maximum number of results to return (default 5, max 20).",
                               required: false
      end

      def initialize(api_key: nil, qps: nil, connection: nil, cache: nil)
        @api_key = api_key || ENV["BRAVE_SEARCH_API_KEY"]
        @qps = qps || default_qps
        @connection = connection || build_connection
        @cache = cache
      end

      def search(query:, max_results: DEFAULT_MAX_RESULTS)
        count = clamp_count(max_results)

        data = if @cache
          @cache.fetch(self.class.tool_name, { query: query, count: count }) { do_search(query, count) }
        else
          do_search(query, count)
        end
        tool_response(content: JSON.generate(data))
      end

      private

      def do_search(query, count)
        if @api_key.nil? || @api_key.to_s.strip.empty?
          return error_payload("missing_api_key", "BRAVE_SEARCH_API_KEY not set")
        end

        throttle!

        response = @connection.get(API_URL) do |req|
          req.headers["Accept"] = "application/json"
          req.headers["X-Subscription-Token"] = @api_key
          req.params["q"] = query
          req.params["count"] = count
        end

        unless response.success?
          return error_payload("http_#{response.status}", response.body.to_s[0, 500])
        end

        parse_results(response.body)
      rescue Faraday::TimeoutError => e
        error_payload("timeout", e.message)
      rescue Faraday::ConnectionFailed => e
        error_payload("connection_failed", e.message)
      rescue Faraday::Error => e
        error_payload("network_error", e.message)
      rescue JSON::ParserError => e
        error_payload("invalid_response", e.message)
      end

      def clamp_count(max_results)
        n = max_results.to_i
        n = DEFAULT_MAX_RESULTS if n <= 0
        [n, MAX_RESULTS_CAP].min
      end

      # Block the caller until at least (1 / qps) seconds have elapsed
      # since the last outbound API call across all instances of this
      # class. Synchronized via a class-level mutex so concurrent agents
      # share the same budget.
      def throttle!
        return if @qps.nil? || @qps <= 0

        interval = 1.0 / @qps.to_f
        self.class.mutex.synchronize do
          last = self.class.last_call_time
          if last
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - last
            sleep(interval - elapsed) if elapsed < interval
          end
          self.class.last_call_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def default_qps
        GrillMe::Config.new.brave_qps
      rescue StandardError
        1.0
      end

      def build_connection
        Faraday.new do |conn|
          conn.options.timeout = TIMEOUT_SECONDS
          conn.options.open_timeout = TIMEOUT_SECONDS
        end
      end

      # Brave returns `{ web: { results: [{ title, url, description, ... }] } }`.
      # Map description -> snippet so the output matches Wikipedia search shape.
      def parse_results(body)
        data = body.is_a?(String) ? JSON.parse(body) : body
        results = data.dig("web", "results") || []
        results.map do |r|
          {
            "title" => r["title"].to_s,
            "url" => r["url"].to_s,
            "snippet" => r["description"].to_s
          }
        end
      end

      def error_payload(error, detail = nil)
        payload = { "error" => error }
        payload["detail"] = detail if detail && !detail.empty?
        payload
      end
    end
  end
end
