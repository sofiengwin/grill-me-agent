require "spec_helper"

RSpec.describe GrillMe::Window do
  let(:as_of) { Date.new(2024, 6, 15) }
  let(:window) { described_class.new(as_of: as_of, years: 20) }

  describe "#window_start" do
    it "is years before as_of" do
      expect(window.window_start).to eq(Date.new(2004, 6, 15))
    end
  end

  describe "#includes?" do
    it "returns true for a current player (nil end_date, start within window)" do
      expect(window.includes?("2010-08-01", nil)).to be true
    end

    it "returns true for a player who ended inside the window" do
      expect(window.includes?("2005-01-01", "2010-12-31")).to be true
    end

    it "returns false for a player who ended before the window started" do
      expect(window.includes?("1990-01-01", "2000-01-01")).to be false
    end

    it "returns true for a player who started before window and is still active" do
      expect(window.includes?("1995-01-01", nil)).to be true
    end

    it "handles year-only start date (treats as full year range)" do
      expect(window.includes?("2010", "2015-06-01")).to be true
    end

    it "handles year-month start date (treats as full month range)" do
      expect(window.includes?("2010-08", "2015-12-31")).to be true
    end

    it "handles year-only end date (treats as full year range)" do
      expect(window.includes?("2003-01-01", "2004")).to be true
    end

    it "handles nil start_date (returns true, unknown)" do
      expect(window.includes?(nil, "2010-12-31")).to be true
    end

    it "handles nil end_date for a player whose start is after as_of (returns false)" do
      expect(window.includes?("2025-01-01", nil)).to be false
    end

    it "rejects malformed date strings" do
      expect { window.includes?("not-a-date", nil) }.to raise_error(GrillMe::WindowError)
      expect { window.includes?("1999-13-01", nil) }.to raise_error(GrillMe::WindowError)
    end

    it "exact boundary: player ended exactly on window start (returns true)" do
      expect(window.includes?("1990-01-01", "2004-06-15")).to be true
    end

    it "exact boundary: player started exactly on as_of (returns true)" do
      expect(window.includes?("2024-06-15", nil)).to be true
    end
  end

  describe "constructor" do
    it "accepts a Date for as_of" do
      w = described_class.new(as_of: Date.new(2024, 1, 1))
      expect(w.as_of).to eq(Date.new(2024, 1, 1))
    end

    it "accepts a parseable string for as_of" do
      w = described_class.new(as_of: "2024-01-01")
      expect(w.as_of).to eq(Date.new(2024, 1, 1))
    end

    it "accepts a Time for as_of" do
      w = described_class.new(as_of: Time.utc(2024, 6, 15, 12, 0, 0))
      expect(w.as_of).to eq(Date.new(2024, 6, 15))
    end

    it "raises WindowError on unparseable as_of string" do
      expect { described_class.new(as_of: "not-a-date") }.to raise_error(GrillMe::WindowError)
    end

    it "defaults years to 20" do
      expect(described_class.new(as_of: as_of).years).to eq(20)
    end
  end

  describe "#parse_date" do
    it "returns nil for nil" do
      expect(window.parse_date(nil)).to be_nil
    end

    it "returns the same Date when given a Date" do
      d = Date.new(2010, 5, 1)
      expect(window.parse_date(d)).to eq(d)
    end

    it "uses earliest day for year-only with role :start" do
      expect(window.parse_date("1999", role: :start)).to eq(Date.new(1999, 1, 1))
    end

    it "uses latest day for year-only with role :end" do
      expect(window.parse_date("1999", role: :end)).to eq(Date.new(1999, 12, 31))
    end

    it "uses earliest day for year-month with role :start" do
      expect(window.parse_date("1999-08", role: :start)).to eq(Date.new(1999, 8, 1))
    end

    it "uses last day of month for year-month with role :end" do
      expect(window.parse_date("1999-08", role: :end)).to eq(Date.new(1999, 8, 31))
      expect(window.parse_date("2000-02", role: :end)).to eq(Date.new(2000, 2, 29))
      expect(window.parse_date("2001-02", role: :end)).to eq(Date.new(2001, 2, 28))
    end

    it "parses exact YYYY-MM-DD" do
      expect(window.parse_date("1999-08-03")).to eq(Date.new(1999, 8, 3))
    end
  end
end
