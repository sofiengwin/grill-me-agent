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
    # @param cache [GrillMe::Cache, nil] When provided and temperature is 0.0, the
    #   returned LLM is wrapped in a CachedLlm so identical chat calls are served
    #   from disk. Non-zero temperatures bypass the wrapper because results are
    #   not deterministic.
    def self.build(provider: DEFAULT_PROVIDER, model: DEFAULT_MODEL,
                   temperature: DEFAULT_TEMPERATURE, api_key: nil, cache: nil)
      builder = PROVIDERS[provider.to_sym]
      raise UnknownProviderError, "unknown LLM provider: #{provider.inspect}" unless builder

      key = api_key || api_key_for(provider.to_sym)
      raise MissingApiKeyError, "missing API key for provider #{provider}" if key.nil? || key.empty?

      llm = builder.call(model: model, temperature: temperature, api_key: key)
      return llm unless cache && temperature.to_f == 0.0

      CachedLlm.new(llm: llm, cache: cache, model: model, temperature: temperature, provider: provider.to_sym)
    end

    def self.api_key_for(provider)
      case provider
      when :openai then ENV.fetch("OPENAI_API_KEY", nil)
      end
    end

    # Forwards `chat` calls through a Cache so identical message sequences served
    # at temperature 0.0 are returned from disk instead of round-tripping to the
    # provider. All other LLM methods (e.g. embeddings) delegate transparently.
    class CachedLlm
      def initialize(llm:, cache:, model:, temperature:, provider: :openai)
        @llm = llm
        @cache = cache
        @model = model
        @temperature = temperature
        @provider = provider
      end

      def chat(messages:, tools: nil, **kwargs)
        key_parts = {
          provider: @provider,
          model: @model,
          temperature: @temperature,
          messages: serialize_messages(messages),
          tools: tools&.map { |t| t.class.respond_to?(:tool_name) ? t.class.tool_name : t.class.name }
        }

        @cache.fetch("llm", key_parts) { @llm.chat(messages: messages, tools: tools, **kwargs) }
      end

      def respond_to_missing?(name, include_private = false)
        @llm.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        return super unless @llm.respond_to?(name)

        @llm.send(name, *args, **kwargs, &block)
      end

      private

      def serialize_messages(messages)
        Array(messages).map do |m|
          if m.is_a?(Hash)
            { role: m[:role] || m["role"], content: m[:content] || m["content"] }
          else
            { role: m.respond_to?(:role) ? m.role : nil, content: m.respond_to?(:content) ? m.content : nil }
          end
        end
      end
    end
  end
end
