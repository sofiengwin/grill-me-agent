require "spec_helper"
require "stringio"

RSpec.describe GrillMe::Log do
  it "writes formatted info lines to the given IO" do
    io = StringIO.new
    logger = described_class.build(level: "info", io: io)
    logger.info("hello")
    expect(io.string).to match(/INFO\s+hello/)
  end

  it "respects the configured level" do
    io = StringIO.new
    logger = described_class.build(level: "warn", io: io)
    logger.info("invisible")
    logger.warn("visible")
    expect(io.string).not_to include("invisible")
    expect(io.string).to include("visible")
  end

  it "defaults unknown levels to info" do
    io = StringIO.new
    logger = described_class.build(level: "bogus", io: io)
    logger.info("shown")
    expect(io.string).to include("shown")
  end
end
