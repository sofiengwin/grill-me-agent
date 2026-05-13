require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe GrillMe::Trace do
  let(:long_text) { "x" * 1500 }

  describe "JsonlSink" do
    it "writes events to jsonl sink as valid JSON lines" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "roster.jsonl")
        jsonl = GrillMe::JsonlSink.new(path)
        trace = described_class.new(level: :info, sinks: [jsonl])

        trace.event(type: "agent_start", tag: "arsenal/roster", data: { prompt_version: "v3" })
        trace.event(type: "tool_call", tag: "arsenal/roster", data: { tool: "wikipedia_page", args: { title: "X" } })
        trace.close

        lines = File.readlines(path)
        expect(lines.size).to eq(2)
        parsed = lines.map { |l| JSON.parse(l) }
        expect(parsed[0]["type"]).to eq("agent_start")
        expect(parsed[0]["tag"]).to eq("arsenal/roster")
        expect(parsed[0]["data"]).to eq("prompt_version" => "v3")
        expect(parsed[1]["data"]["tool"]).to eq("wikipedia_page")
      end
    end
  end

  describe "truncation" do
    it "truncates long fields for stderr but not jsonl" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "roster.jsonl")
        io = StringIO.new
        trace = described_class.new(
          level: :info,
          sinks: [GrillMe::StderrSink.new(io: io), GrillMe::JsonlSink.new(path)]
        )

        trace.event(type: "llm_response", tag: "t", data: { content: long_text })
        trace.close

        expect(io.string).not_to include(long_text)
        expect(io.string).to include("…")
        jsonl_line = File.read(path)
        expect(JSON.parse(jsonl_line)["data"]["content"]).to eq(long_text)
      end
    end
  end

  describe "log levels" do
    it "respects log level quiet (info events suppressed on stderr, still written to jsonl)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "roster.jsonl")
        io = StringIO.new
        trace = described_class.new(
          level: :quiet,
          sinks: [GrillMe::StderrSink.new(io: io), GrillMe::JsonlSink.new(path)]
        )

        trace.event(type: "tool_call", tag: "t", data: { tool: "x", args: {} })
        trace.event(type: "agent_end", tag: "t", data: { status: "error" })
        trace.close

        expect(io.string).not_to include("tool_call")
        expect(io.string).to include("agent_end error")
        expect(File.readlines(path).size).to eq(2)
      end
    end

    it "respects log level debug (full LLM messages on stderr)" do
      io = StringIO.new
      trace = described_class.new(level: :debug, sinks: [GrillMe::StderrSink.new(io: io)])

      trace.event(type: "llm_response", tag: "t", data: { content: long_text })

      expect(io.string).to include(long_text)
    end
  end

  describe "event payload" do
    it "includes timestamp, tag, latency_ms, cached in every event" do
      captured = []
      sink = Class.new do
        define_method(:write) { |ev, level: nil| captured << ev }
        define_method(:close) {}
      end.new
      trace = described_class.new(level: :info, sinks: [sink])

      trace.event(type: "tool_result", tag: "arsenal/roster", data: { tool: "x" }, latency_ms: 45, cached: true)

      ev = captured.first
      expect(ev).to include(:timestamp, :tag, :latency_ms, :cached, :type, :data)
      expect(ev[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
      expect(ev[:tag]).to eq("arsenal/roster")
      expect(ev[:latency_ms]).to eq(45)
      expect(ev[:cached]).to be(true)
    end
  end

  describe "StderrSink formatting" do
    it "produces tagged lines with timestamp and event body" do
      io = StringIO.new
      trace = described_class.new(level: :info, sinks: [GrillMe::StderrSink.new(io: io)])

      trace.event(type: "tool_call", tag: "arsenal/roster", data: { tool: "wikipedia_page", args: { title: "Thierry Henry" } })
      trace.event(type: "tool_result", tag: "arsenal/roster", data: { tool: "wikipedia_page" }, latency_ms: 45, cached: true)
      trace.event(type: "agent_end", tag: "arsenal/roster", data: { status: "success" })

      lines = io.string.lines
      expect(lines[0]).to match(/\[\d{4}-\d{2}-\d{2}T.*Z\] \[arsenal\/roster\] tool_call wikipedia_page\(title="Thierry Henry"\)/)
      expect(lines[1]).to include("[arsenal/roster] tool_result wikipedia_page ok (45ms, cached)")
      expect(lines[2]).to include("[arsenal/roster] agent_end success")
    end
  end

  describe "multiple sinks" do
    it "fans an event out to both stderr and jsonl" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "roster.jsonl")
        io = StringIO.new
        trace = described_class.new(
          level: :info,
          sinks: [GrillMe::StderrSink.new(io: io), GrillMe::JsonlSink.new(path)]
        )

        trace.event(type: "agent_start", tag: "arsenal/roster", data: { prompt_version: "v3" })
        trace.close

        expect(io.string).to include("[arsenal/roster] agent_start")
        expect(File.read(path)).to include('"type":"agent_start"')
      end
    end
  end
end
