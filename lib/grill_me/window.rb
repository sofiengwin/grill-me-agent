require "date"

module GrillMe
  # Trailing N-year inclusion window, evaluated against player tenure ranges
  # that may be expressed at year, year-month, or year-month-day precision.
  # nil end_date means "still at club"; nil start_date means "unknown" and is
  # kept by default rather than dropped.
  class Window
    YEAR_RE = /\A(\d{4})\z/
    YEAR_MONTH_RE = /\A(\d{4})-(\d{1,2})\z/
    YEAR_MONTH_DAY_RE = /\A(\d{4})-(\d{1,2})-(\d{1,2})\z/

    attr_reader :as_of, :window_start, :years

    def initialize(as_of:, years: 20)
      @years = years
      @as_of = coerce_as_of(as_of)
      @window_start = @as_of.prev_year(years)
    end

    def includes?(start_date, end_date)
      player_start = parse_date(start_date, role: :start)
      return true if player_start.nil?

      player_end = parse_date(end_date, role: :end)
      return player_start <= @as_of if player_end.nil?

      player_start <= @as_of && player_end >= @window_start
    end

    def parse_date(value, role: :start)
      return nil if value.nil?
      return value if value.is_a?(Date) && !value.is_a?(DateTime)
      return value.to_date if value.is_a?(Date) || value.is_a?(Time)

      str = value.to_s.strip
      return nil if str.empty?

      case str
      when YEAR_RE
        year = Regexp.last_match(1).to_i
        role == :end ? Date.new(year, 12, 31) : Date.new(year, 1, 1)
      when YEAR_MONTH_RE
        year = Regexp.last_match(1).to_i
        month = Regexp.last_match(2).to_i
        role == :end ? Date.new(year, month, -1) : Date.new(year, month, 1)
      when YEAR_MONTH_DAY_RE
        Date.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i)
      else
        raise WindowError, "Unparseable date: #{value.inspect}"
      end
    rescue Date::Error => e
      raise WindowError, "Unparseable date: #{value.inspect} (#{e.message})"
    end

    private

    def coerce_as_of(value)
      case value
      when Date then value.is_a?(DateTime) ? value.to_date : value
      when Time then value.to_date
      when String
        begin
          Date.parse(value)
        rescue ArgumentError => e
          raise WindowError, "Unparseable as_of: #{value.inspect} (#{e.message})"
        end
      else
        raise WindowError, "Unsupported as_of type: #{value.class}"
      end
    end
  end
end
