require "wikipedia"
require "json"
require "langchain"

module GrillMe
  module Tools
    # Langchain tool that fetches a single Wikipedia page by exact title.
    # Returns a structured payload (title, url, summary, sections, infobox)
    # with the textual portions truncated to ~12k chars so a single tool
    # call cannot blow past the model context window.
    class WikipediaPage
      extend Langchain::ToolDefinition

      MAX_CONTENT_CHARS = 12_000
      INFOBOX_REGEX = /\{\{\s*Infobox[^\n]*\n(.*?)\n\}\}/mi

      # Override the auto-derived snake_case class name so the LLM sees
      # the friendlier tool surface "wikipedia_page__fetch" rather than
      # the namespaced "grill_me_tools_wikipedia_page__fetch".
      def self.tool_name
        "wikipedia_page"
      end

      define_function :fetch,
                      description: "Fetch a Wikipedia page by exact title and " \
                                   "return its summary, section headings/text, and infobox " \
                                   "key-value pairs. Use this to look up a player's biography." do
        property :title, type: "string",
                         description: "Exact Wikipedia page title (e.g. 'Thierry Henry').",
                         required: true
      end

      def initialize(client: ::Wikipedia)
        @client = client
      end

      def fetch(title:)
        page = @client.find(title)
        if page.nil? || page.text.nil? || page.text.empty?
          return tool_response(content: JSON.generate("error" => "page not found", "title" => title))
        end

        payload = {
          "title" => page.title,
          "url" => page.fullurl,
          "summary" => truncate(page.summary.to_s),
          "sections" => parse_sections(page.text.to_s),
          "infobox" => extract_infobox(page.content.to_s)
        }
        tool_response(content: JSON.generate(payload))
      end

      private

      def truncate(str, limit = MAX_CONTENT_CHARS)
        return str if str.length <= limit

        "#{str[0, limit]}\n[...truncated]"
      end

      # Splits the plain-text extract into `{ heading:, text: }` blocks. The
      # intro (everything before the first `==`) is dropped because the
      # caller already gets it via `summary`.
      def parse_sections(extract)
        return [] if extract.empty?

        blocks = extract.split(/^==\s*([^=]+?)\s*==\s*$/)
        sections = []
        running = 0
        i = 1
        while i < blocks.length && running < MAX_CONTENT_CHARS
          heading = blocks[i].to_s.strip
          body = blocks[i + 1].to_s.strip
          remaining = MAX_CONTENT_CHARS - running
          chunk = body.length > remaining ? "#{body[0, remaining]}\n[...truncated]" : body
          sections << { "heading" => heading, "text" => chunk }
          running += chunk.length
          i += 2
        end
        sections
      end

      # Pulls a flat hash of `key => value` pairs out of the first
      # `{{Infobox ...}}` template in the wikitext. Returns nil when no
      # infobox is present so the LLM can tell the difference between
      # "missing" and "empty".
      def extract_infobox(wikitext)
        return nil if wikitext.empty?

        match = wikitext.match(INFOBOX_REGEX)
        return nil unless match

        pairs = match[1].split("\n|").each_with_object({}) do |line, acc|
          k, v = parse_infobox_line(line)
          acc[k] = v if k && v
        end
        pairs.empty? ? nil : pairs
      end

      def parse_infobox_line(line)
        return nil unless line.include?("=")

        key, value = line.split("=", 2)
        k = key.to_s.strip.sub(/^\|\s*/, "").strip
        v = clean_wikitext(value.to_s.strip)
        return nil if k.empty? || v.empty?

        [k, v]
      end

      def clean_wikitext(value)
        value.gsub(/\[\[(?:[^|\]]*\|)?([^\]]+)\]\]/, '\1')
             .gsub(%r{<ref[^>]*>.*?</ref>}m, "")
             .gsub(%r{<ref[^>]*/>}, "")
             .gsub(/<!--.*?-->/m, "")
             .gsub(/'''?/, "")
             .strip
      end
    end
  end
end
