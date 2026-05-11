require "faraday"
require "json"
require "langchain"

module GrillMe
  module Tools
    # Langchain tool that wraps the MediaWiki opensearch API. Given a free-form
    # query string it returns the top 5 matching pages as a JSON array of
    # `{ title, snippet, url }` objects so the agent can pick the right page
    # before calling `WikipediaPage` for the full biography.
    class WikipediaSearch
      extend Langchain::ToolDefinition

      API_URL = "https://en.wikipedia.org/w/api.php".freeze
      LIMIT = 5
      TIMEOUT_SECONDS = 10

      # Override the auto-derived snake_case class name so the LLM sees
      # the friendlier tool surface "wikipedia_search__search" rather than
      # the namespaced "grill_me_tools_wikipedia_search__search".
      def self.tool_name
        "wikipedia_search"
      end

      define_function :search,
                      description: "Search Wikipedia for pages matching a free-form query " \
                                   "and return the top results as { title, snippet, url } " \
                                   "objects. Use this to disambiguate before fetching a page." do
        property :query, type: "string",
                         description: "Search query, e.g. a player name or phrase.",
                         required: true
      end

      def initialize(connection: nil)
        @connection = connection || default_connection
      end

      def search(query:)
        response = @connection.get(API_URL) do |req|
          req.params["action"] = "opensearch"
          req.params["format"] = "json"
          req.params["limit"] = LIMIT
          req.params["search"] = query
        end

        unless response.success?
          return tool_response(content: JSON.generate("error" => "http #{response.status}", "query" => query))
        end

        results = parse_results(response.body)
        tool_response(content: JSON.generate(results))
      rescue Faraday::Error, JSON::ParserError => e
        tool_response(content: JSON.generate("error" => e.message, "query" => query))
      end

      private

      def default_connection
        Faraday.new do |f|
          f.options.timeout = TIMEOUT_SECONDS
          f.options.open_timeout = TIMEOUT_SECONDS
          f.adapter Faraday.default_adapter
        end
      end

      # MediaWiki opensearch returns `[query, [titles], [snippets], [urls]]`.
      # Zip the three result arrays into objects, defaulting missing entries
      # to empty strings so the JSON shape is always uniform.
      def parse_results(body)
        data = body.is_a?(String) ? JSON.parse(body) : body
        return [] unless data.is_a?(Array) && data.length >= 4

        titles = Array(data[1])
        snippets = Array(data[2])
        urls = Array(data[3])

        titles.each_with_index.map do |title, i|
          {
            "title" => title.to_s,
            "snippet" => snippets[i].to_s,
            "url" => urls[i].to_s
          }
        end
      end
    end
  end
end
