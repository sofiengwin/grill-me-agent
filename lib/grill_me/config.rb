module GrillMe
  # Resolves configuration in priority order:
  #   CLI flag > GRILL_ME_* env var > built-in default
  #
  # Validates the presence of required upstream API keys at startup so the
  # caller fails fast with a friendly error before any work begins.
  class Config
    REQUIRED_ENV = %w[OPENAI_API_KEY BRAVE_SEARCH_API_KEY].freeze

    DEFAULTS = {
      window_years: 20,
      concurrency: 5,
      log_level: "info"
    }.freeze

    attr_reader :window_years, :concurrency, :log_level

    def initialize(env: ENV, overrides: {})
      @env = env
      @window_years = pick(:window_years, overrides, "WINDOW_YEARS", :to_i)
      @concurrency = pick(:concurrency, overrides, "CONCURRENCY", :to_i)
      @log_level = pick(:log_level, overrides, "LOG_LEVEL", :to_s)
    end

    def validate_required_env!
      missing = REQUIRED_ENV.reject { |key| @env[key] && !@env[key].strip.empty? }
      return if missing.empty?

      raise ConfigError, friendly_missing_message(missing)
    end

    def openai_api_key
      @env["OPENAI_API_KEY"]
    end

    def brave_search_api_key
      @env["BRAVE_SEARCH_API_KEY"]
    end

    private

    def pick(key, overrides, env_suffix, coerce)
      raw = overrides[key]
      raw = @env["GRILL_ME_#{env_suffix}"] if raw.nil? || raw.to_s.empty?
      raw = DEFAULTS.fetch(key) if raw.nil? || raw.to_s.empty?
      raw.send(coerce)
    end

    def friendly_missing_message(missing)
      list = missing.map { |k| "  - #{k}" }.join("\n")
      <<~MSG
        Missing required environment variable#{"s" unless missing.size == 1}:
        #{list}

        Export the variable#{"s" unless missing.size == 1} in your shell, e.g.:
        #{missing.map { |k| "  export #{k}=..." }.join("\n")}
      MSG
    end
  end
end
