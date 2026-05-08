require "grill_me/version"
require "grill_me/logger"
require "grill_me/config"
require "grill_me/input"
require "grill_me/schema"
require "grill_me/assembler"
require "grill_me/output"
require "grill_me/cli"

module GrillMe
  class Error < StandardError; end
  class ConfigError < Error; end
  class InputError < Error; end
  class SchemaError < Error; end
end
