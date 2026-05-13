require "date"

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
      log_level: "info",
      brave_qps: 1.0,
      per_club_timeout_s: 600,
      temperature: 0.0,
      no_cache: false,
      refresh_cache: false,
      quiet: false,
      verbose: false
    }.freeze

    AS_OF_PATTERN = /^\d{4}-\d{2}-\d{2}$/.freeze

    attr_reader :window_years, :concurrency, :log_level, :brave_qps, :as_of, :per_club_timeout_s,
                :temperature, :no_cache, :refresh_cache, :quiet, :verbose

    def initialize(env: ENV, overrides: {})
      @env = env
      @window_years = pick(:window_years, overrides, "WINDOW_YEARS", :to_i)
      @concurrency = pick(:concurrency, overrides, "CONCURRENCY", :to_i)
      @log_level = pick(:log_level, overrides, "LOG_LEVEL", :to_s)
      @brave_qps = pick(:brave_qps, overrides, "BRAVE_QPS", :to_f)
      @per_club_timeout_s = pick(:per_club_timeout_s, overrides, "PER_CLUB_TIMEOUT_S", :to_i)
      @temperature = pick(:temperature, overrides, "TEMPERATURE", :to_f)
      @no_cache = pick_bool(:no_cache, overrides, "NO_CACHE") || false
      @refresh_cache = pick_bool(:refresh_cache, overrides, "REFRESH_CACHE") || false
      @quiet = pick_bool(:quiet, overrides, "QUIET") || false
      @verbose = pick_bool(:verbose, overrides, "VERBOSE") || false
      @as_of = pick_optional(:as_of, overrides, "AS_OF")
      validate_brave_qps!
      validate_as_of!
    end

    # Returns the Trace log level symbol implied by quiet/verbose flags.
    # quiet wins over verbose; default is :info.
    def trace_level
      return :quiet if @quiet
      return :debug if @verbose

      :info
    end

    def as_of_date
      return nil if @as_of.nil? || @as_of.empty?

      Date.parse(@as_of)
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

    def validate_brave_qps!
      return if @brave_qps.is_a?(Numeric) && @brave_qps.positive?

      raise ConfigError, "brave_qps must be a positive number (got #{@brave_qps.inspect})"
    end

    def validate_as_of!
      return if @as_of.nil? || @as_of.empty?
      return if @as_of.match?(AS_OF_PATTERN)

      raise ConfigError, "as_of must be YYYY-MM-DD format"
    end

    def pick(key, overrides, env_suffix, coerce)
      raw = overrides[key]
      raw = @env["GRILL_ME_#{env_suffix}"] if raw.nil? || raw.to_s.empty?
      raw = DEFAULTS.fetch(key) if raw.nil? || raw.to_s.empty?
      raw.send(coerce)
    end

    def pick_optional(key, overrides, env_suffix)
      raw = overrides[key]
      raw = @env["GRILL_ME_#{env_suffix}"] if raw.nil? || raw.to_s.empty?
      return nil if raw.nil? || raw.to_s.empty?

      raw.to_s
    end

    def pick_bool(key, overrides, env_suffix)
      raw = overrides[key] || @env["GRILL_ME_#{env_suffix}"]
      return false if raw.nil? || raw.to_s.empty?
      return true if raw == true
      return false if raw == false

      %w[1 true yes].include?(raw.to_s.downcase)
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
