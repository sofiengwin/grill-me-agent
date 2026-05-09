$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "grill_me"

require "vcr"
require "webmock/rspec"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

# Live-recording gate.
#
# `LIVE=1` flips the suite into "talk to the real internet" mode: WebMock
# allows external HTTP, VCR re-records cassettes, and any test tagged
# `:live` is run. Without it, WebMock blocks all external HTTP and VCR
# replays whatever's on disk -- so CI is fully deterministic and never
# needs an API key.
LIVE_MODE = ENV["LIVE"] == "1"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("fixtures", __dir__)
  c.hook_into :webmock
  c.configure_rspec_metadata!
  c.default_cassette_options = {
    record: LIVE_MODE ? :new_episodes : :none,
    match_requests_on: %i[method uri body]
  }
  c.filter_sensitive_data("<OPENAI_API_KEY>") { ENV.fetch("OPENAI_API_KEY", nil) }
end

WebMock.disable_net_connect!(allow_localhost: true) unless LIVE_MODE

# Quiet langchainrb's verbose stdout/stderr chatter during tests.
Langchain.logger.level = Logger::ERROR if defined?(Langchain) && Langchain.respond_to?(:logger)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = false
  config.order = :random
  Kernel.srand(config.seed)

  config.filter_run_excluding(live: true) unless LIVE_MODE
end
