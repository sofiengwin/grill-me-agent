require "langchain"

module GrillMe
  # Provider/model factory for LLMs. Returns a Langchain LLM instance whose
  # uniform `chat(messages:, tools:)` surface lets `Langchain::Assistant`
  # drive the agent and lets future providers (Anthropic, ...) slot in
  # behind the same factory call without touching agent code.
  module Llm
    DEFAULT_PROVIDER = :openai
    DEFAULT_MODEL = "gpt-4o-mini".freeze
    DEFAULT_TEMPERATURE = 0.0

    PROVIDERS = {
      openai: lambda { |model:, temperature:, api_key:|
        Langchain::LLM::OpenAI.new(
          api_key: api_key,
          default_options: {
            chat_model: model,
            temperature: temperature
          }
        )
      }
    }.freeze

    class UnknownProviderError < GrillMe::Error; end
    class MissingApiKeyError < GrillMe::Error; end

    # Build a configured LLM instance.
    #
    # @param provider [Symbol] :openai (default). Anthropic etc. land in later slices.
    # @param model [String] Model id, e.g. "gpt-4o-mini".
    # @param temperature [Float] Default 0.0 so replays are deterministic.
    # @param api_key [String] Provider API key. Defaults to the appropriate env var.
    def self.build(provider: DEFAULT_PROVIDER, model: DEFAULT_MODEL,
                   temperature: DEFAULT_TEMPERATURE, api_key: nil)
      builder = PROVIDERS[provider.to_sym]
      raise UnknownProviderError, "unknown LLM provider: #{provider.inspect}" unless builder

      key = api_key || api_key_for(provider.to_sym)
      raise MissingApiKeyError, "missing API key for provider #{provider}" if key.nil? || key.empty?

      builder.call(model: model, temperature: temperature, api_key: key)
    end

    def self.api_key_for(provider)
      case provider
      when :openai then ENV.fetch("OPENAI_API_KEY", nil)
      end
    end
  end
end
