require "erb"
require "json"
require "langchain"

module GrillMe
  module Agents
    # Wraps a `Langchain::Assistant` configured with the Wikipedia tool.
    # Drives one player-research conversation, parses the model's final
    # JSON, validates it against the player sub-schema, and asks the
    # assistant to fix it (up to `MAX_SCHEMA_RETRIES` times) when invalid.
    class PlayerAgent
      MAX_ITERATIONS = 8
      MAX_SCHEMA_RETRIES = 2
      PROMPT_PATH = File.expand_path("../prompts/player_agent.md.erb", __dir__)

      class AgentError < GrillMe::Error; end
      class MaxIterationsError < AgentError; end
      class InvalidJSONError < AgentError; end
      class SchemaValidationError < AgentError; end

      attr_reader :iterations, :prompt_version

      def initialize(llm:, tools: nil, cache: nil)
        @llm = llm
        @cache = cache
        @tools = tools || default_tools(cache: cache)
        @iterations = 0
        @prompt_version = nil
      end

      # Run the agent for a single player/club pair and return a hash that
      # validates against `Schema.player`.
      def run(player_name:, club_name:, club_country: nil)
        instructions = render_prompt(player_name: player_name, club_name: club_name, club_country: club_country)
        assistant = build_assistant(instructions: instructions)
        assistant.add_message(role: "user",
                              content: "Begin researching #{player_name}'s stint at #{club_name} now.")

        record = drive(assistant)
        record["club_name"] ||= club_name
        record["club_country"] ||= club_country if club_country
        record
      end

      private

      def default_tools(cache:)
        [GrillMe::Tools::WikipediaPage.new(cache: cache)]
      end

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

      # Run the assistant loop, then parse + validate the final JSON.
      # On schema failure, push a corrective user message and run again,
      # up to `MAX_SCHEMA_RETRIES` times.
      def drive(assistant)
        retries = 0
        loop do
          assistant.run!
          last = last_assistant_message(assistant)
          raise AgentError, "assistant produced no final message" if last.nil?

          record = parse_json!(last)
          errors = GrillMe::Schema.player_errors(record)
          return record if errors.empty?

          if retries >= MAX_SCHEMA_RETRIES
            raise SchemaValidationError, "schema invalid after #{retries} retries: #{format_errors(errors)}"
          end

          retries += 1
          assistant.add_message(role: "user", content: schema_correction_message(errors))
        end
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

      def schema_correction_message(errors)
        bullets = errors.first(5).map do |err|
          "  - #{err["data_pointer"].empty? ? "/" : err["data_pointer"]}: #{err["error"]}"
        end.join("\n")
        "Your last response failed schema validation:\n#{bullets}\n\n" \
          "Reply with ONLY the corrected JSON object. No prose, no code fences."
      end

      def format_errors(errors)
        errors.first(5).map { |e| "#{e["data_pointer"]}=#{e["error"]}" }.join("; ")
      end

      def render_prompt(player_name:, club_name:, club_country:)
        raw = File.read(PROMPT_PATH)
        @prompt_version = parse_prompt_version(raw)
        body = strip_front_matter(raw)
        ERB.new(body, trim_mode: "-").result_with_hash(
          player_name: player_name,
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
