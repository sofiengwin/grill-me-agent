require "logger"

module GrillMe
  # Thin wrapper around stdlib Logger that defaults to stderr at info level.
  # Slice 10 will replace this with a structured Trace.
  module Log
    LEVELS = {
      "debug" => ::Logger::DEBUG,
      "info" => ::Logger::INFO,
      "warn" => ::Logger::WARN,
      "error" => ::Logger::ERROR
    }.freeze

    def self.build(level: "info", io: $stderr)
      logger = ::Logger.new(io)
      logger.level = LEVELS.fetch(level.to_s) { ::Logger::INFO }
      logger.formatter = proc do |severity, time, _progname, msg|
        "#{time.utc.iso8601} #{severity.ljust(5)} #{msg}\n"
      end
      logger
    end
  end
end
