require "faraday"
require "json"
require "langchain"

module GrillMe
  module Tools
    # Langchain tool that executes a SPARQL query against the Wikidata Query
    # Service and returns a flat array of row hashes (one hash per binding,
    # keyed by variable name with the raw literal/URI value).
    #
    # Results are hard-capped at MAX_ROWS so a runaway query cannot blow past
    # the model context window, and HTTP calls have a 30s timeout. Network
    # and parse failures are surfaced as `{ "error": "..." }` payloads rather
    # than raising, so the agent loop can recover and try a different query.
    class WikidataSparql
      extend Langchain::ToolDefinition

      ENDPOINT = "https://query.wikidata.org/sparql".freeze
      MAX_ROWS = 500
      TIMEOUT_SECONDS = 30
      USER_AGENT = "grill-me-agent/0.1 (https://github.com/; SPARQL tool)".freeze

      # Override the auto-derived snake_case class name so the LLM sees
      # the friendlier "wikidata_sparql" tool surface rather than the
      # namespaced "grill_me_tools_wikidata_sparql".
      def self.tool_name
        "wikidata_sparql"
      end

      define_function :query,
                      description: "Run a SPARQL query against the Wikidata Query " \
                                   "Service (https://query.wikidata.org/sparql) and return " \
                                   "the result rows. Use this to look up structured facts " \
                                   "about entities (e.g. a club's current squad, a player's " \
                                   "teams). Results are capped at 500 rows." do
        property :sparql, type: "string",
                          description: "A complete SPARQL query string. " \
                                       "Always add LIMIT to keep the result set small.",
                          required: true
      end

      def initialize(connection: nil, cache: nil)
        @connection = connection || build_connection
        @cache = cache
      end

      def query(sparql:)
        if @cache
          @cache.fetch(self.class.tool_name, { sparql: sparql }) { perform_query(sparql) }
        else
          perform_query(sparql)
        end
      end

      private

      def perform_query(sparql)
        response = @connection.post(ENDPOINT) do |req|
          req.headers["Accept"] = "application/sparql-results+json"
          req.headers["User-Agent"] = USER_AGENT
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = URI.encode_www_form(query: sparql)
        end

        unless response.success?
          return error_response("HTTP #{response.status}", response.body.to_s[0, 500])
        end

        rows = parse_bindings(response.body)
        truncated = rows.length > MAX_ROWS
        payload = {
          "rows" => rows.first(MAX_ROWS),
          "row_count" => [rows.length, MAX_ROWS].min,
          "truncated" => truncated
        }
        tool_response(content: JSON.generate(payload))
      rescue Faraday::TimeoutError => e
        error_response("timeout", e.message)
      rescue Faraday::ConnectionFailed => e
        error_response("connection_failed", e.message)
      rescue Faraday::Error => e
        error_response("network_error", e.message)
      rescue JSON::ParserError => e
        error_response("invalid_response", e.message)
      end

      def build_connection
        Faraday.new do |conn|
          conn.options.timeout = TIMEOUT_SECONDS
          conn.options.open_timeout = TIMEOUT_SECONDS
        end
      end

      # Flatten the SPARQL JSON results format
      #   { results: { bindings: [{ var: { type:, value: } }, ...] } }
      # into [{ var => value, ... }, ...], dropping the type wrapper. Variables
      # absent from a given row are simply omitted from that row's hash.
      def parse_bindings(body)
        parsed = body.is_a?(String) ? JSON.parse(body) : body
        bindings = parsed.dig("results", "bindings") || []
        bindings.map do |binding|
          binding.each_with_object({}) do |(var, cell), acc|
            value = cell.is_a?(Hash) ? cell["value"] : nil
            acc[var] = value unless value.nil?
          end
        end
      end

      def error_response(error, detail = nil)
        payload = { "error" => error }
        payload["detail"] = detail if detail && !detail.empty?
        tool_response(content: JSON.generate(payload))
      end
    end
  end
end
