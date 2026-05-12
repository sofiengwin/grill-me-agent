require "json"
require "time"
require "fileutils"

module GrillMe
  # Structured event logger that fans out to multiple sinks.
  # See Slice 10 spec: tagged stderr + per-agent .jsonl transcripts.
  class Trace
    LEVELS = { quiet: 0, info: 1, debug: 2 }.freeze

    def initialize(level: :info, sinks: [])
      @level = level.to_sym
      raise ArgumentError, "unknown level #{@level}" unless LEVELS.key?(@level)
      @sinks = Array(sinks)
    end

    attr_reader :level, :sinks

    def event(type:, tag: nil, data: {}, latency_ms: nil, cached: nil)
      ev = {
        timestamp: Time.now.utc.iso8601,
        type: type.to_s,
        tag: tag,
        latency_ms: latency_ms,
        cached: cached,
        data: data || {}
      }
      @sinks.each { |s| s.write(ev, level: @level) }
      ev
    end

    def close
      @sinks.each { |s| s.close if s.respond_to?(:close) }
    end
  end

  # Formats events as tagged stderr lines with truncation for long fields.
  class StderrSink
    TRUNCATE_AT = 500

    def initialize(io: $stderr)
      @io = io
    end

    def write(event, level: :info)
      level = level.to_sym
      return unless emit?(event, level)
      @io.puts(format_line(event, level))
    end

    def close; end

    private

    def emit?(event, level)
      case level
      when :quiet
        event[:type] == "error" || event.dig(:data, :status) == "error" || event.dig(:data, "status") == "error"
      else
        true
      end
    end

    def format_line(event, level)
      tag = event[:tag] ? "[#{event[:tag]}] " : ""
      "[#{event[:timestamp]}] #{tag}#{format_body(event, level)}"
    end

    def format_body(event, level)
      data = event[:data] || {}
      case event[:type]
      when "tool_call"
        "tool_call #{data[:tool] || data['tool']}(#{format_args(data[:args] || data['args'] || {})})"
      when "tool_result"
        "tool_result #{data[:tool] || data['tool']} #{data[:status] || data['status'] || 'ok'}#{meta_suffix(event)}"
      when "llm_request"
        if level == :debug
          msgs = data[:messages] || data['messages']
          "llm_request#{meta_suffix(event)} #{msgs.inspect}"
        else
          msgs = data[:messages] || data['messages'] || []
          "llm_request#{meta_suffix(event)} (#{msgs.length} msgs)"
        end
      when "llm_response"
        content = (data[:content] || data['content']).to_s
        body = level == :debug ? content : truncate(content, TRUNCATE_AT)
        "llm_response#{meta_suffix(event)} #{body}"
      when "agent_start"
        "agent_start"
      when "agent_end"
        "agent_end #{data[:status] || data['status']}#{meta_suffix(event)}"
      else
        "#{event[:type]} #{data.inspect}"
      end
    end

    def meta_suffix(event)
      parts = []
      parts << "#{event[:latency_ms]}ms" if event[:latency_ms]
      parts << "cached" if event[:cached]
      parts.empty? ? "" : " (#{parts.join(', ')})"
    end

    def format_args(args)
      args.map do |k, v|
        val = v.is_a?(String) ? %("#{truncate(v, 100)}") : v.inspect
        "#{k}=#{val}"
      end.join(", ")
    end

    def truncate(str, limit)
      return str if str.length <= limit
      "#{str[0, limit]}…"
    end
  end

  # Appends one JSON object per line to a file. Full fidelity, no truncation.
  class JsonlSink
    def initialize(path)
      @path = path
      FileUtils.mkdir_p(File.dirname(path))
      @file = File.open(path, "a")
      @file.sync = true
    end

    attr_reader :path

    def write(event, level: nil)
      @file.puts(JSON.generate(stringify_keys(event)))
    end

    def close
      @file.close if @file && !@file.closed?
    end

    private

    def stringify_keys(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
      when Array then obj.map { |v| stringify_keys(v) }
      else obj
      end
    end
  end
end
