require "erb"
require "json"
require "langchain"

module GrillMe
  module Agents
    # Wraps a `Langchain::Assistant` configured with the Wikipedia search and
    # page tools. Drives one club-roster research conversation, parses the
    # model's final JSON array, validates that each entry has a non-empty
    # `name`, and caps the result at `ROSTER_SANITY_CAP` players.
    class RosterAgent
      MAX_ITERATIONS = 15
      MAX_SCHEMA_RETRIES = 2
      ROSTER_SANITY_CAP = 250
      PROMPT_PATH = File.expand_path("../prompts/roster_agent.md.erb", __dir__)

      class AgentError < GrillMe::Error; end
      class MaxIterationsError < AgentError; end
      class InvalidJSONError < AgentError; end

      attr_reader :iterations, :prompt_version

      def initialize(llm:, tools: nil)
        @llm = llm
        @tools = tools || [GrillMe::Tools::WikipediaSearch.new, GrillMe::Tools::WikipediaPage.new]
        @iterations = 0
        @prompt_version = nil
      end

      # Run the agent for a single club and return an array of player hashes
      # of the form { "name" => ..., "wikidata_id" => ..., "wikipedia_url" => ... }.
      def run(club_name:, club_country: nil)
        instructions = render_prompt(club_name: club_name, club_country: club_country)
        assistant = build_assistant(instructions: instructions)
        assistant.add_message(role: "user",
                              content: "Begin researching the senior-team roster of #{club_name} now.")

        roster = drive(assistant)
        roster.first(ROSTER_SANITY_CAP)
      end

      private

      def build_assistant(instructions:)
        agent = self
        Langchain::Assistant.new(
          llm: @llm,
          instructions: instructions,
          tools: @tools,
          parallel_tool_calls: false,
          add_message_callback: ->(message) { agent.send(:track_message, message) }
        )
      end

      # Run the assistant loop, then parse + validate the final JSON array.
      def drive(assistant)
        assistant.run!
        last = last_assistant_message(assistant)
        raise AgentError, "assistant produced no final message" if last.nil?

        parsed = parse_json!(last)
        validate_roster!(parsed)
        parsed
      end

      # Counts assistant turns (LLM messages, regardless of whether they
      # call tools or finalize) and aborts via raise once we exceed the
      # MAX_ITERATIONS cap. Bubbles out through Assistant#run!.
      def track_message(message)
        return unless message.respond_to?(:standard_role) && message.standard_role == :llm

        @iterations += 1
        return unless @iterations > MAX_ITERATIONS

        raise MaxIterationsError, "max_iterations_reached (#{MAX_ITERATIONS})"
      end

      def last_assistant_message(assistant)
        assistant.messages.reverse.find { |m| m.standard_role == :llm && m.content && !m.content.strip.empty? }&.content
      end

      # The model occasionally wraps the JSON in a ```json fence even though
      # the prompt forbids it; strip that before parsing so a stray fence
      # doesn't burn a corrective retry.
      def parse_json!(content)
        stripped = content.strip
        stripped = stripped.sub(/\A```(?:json)?\s*/, "").sub(/```\z/, "").strip
        JSON.parse(stripped)
      rescue JSON::ParserError => e
        raise InvalidJSONError, "could not parse JSON: #{e.message}\nGot: #{content[0, 300]}"
      end

      def validate_roster!(parsed)
        unless parsed.is_a?(Array)
          raise InvalidJSONError, "expected a JSON array at the top level, got #{parsed.class}"
        end

        parsed.each_with_index do |entry, idx|
          unless entry.is_a?(Hash)
            raise InvalidJSONError, "roster entry at index #{idx} is not an object: #{entry.inspect}"
          end

          name = entry["name"]
          unless name.is_a?(String) && !name.strip.empty?
            raise InvalidJSONError, "roster entry at index #{idx} is missing a non-empty 'name' string"
          end
        end
      end

      def render_prompt(club_name:, club_country:)
        raw = File.read(PROMPT_PATH)
        @prompt_version = parse_prompt_version(raw)
        body = strip_front_matter(raw)
        ERB.new(body, trim_mode: "-").result_with_hash(
          club_name: club_name,
          club_country: club_country
        )
      end

      def parse_prompt_version(raw)
        first = raw.lines.first.to_s.strip
        return nil unless first.start_with?("version:")

        first.sub(/^version:\s*/, "").strip
      end

      def strip_front_matter(raw)
        lines = raw.lines
        return raw unless lines.first&.start_with?("version:")

        rest = lines.drop(1)
        rest = rest.drop(1) if rest.first&.strip == "---"
        rest.join
      end
    end
  end
end
