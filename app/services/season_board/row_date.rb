# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::RowDate
  #
  # Lenient parser for the date column of the FIN "Riepilogo Eventi" rows stored by the
  # watcher snapshot, combined with the year of the table caption.
  #
  # Supported formats (separators '/', '_' or '.' between day & month):
  # - "24/10"       => 24 Oct
  # - "21-22/11"    => 21..22 Nov (the month is inherited from the last part)
  # - "31/10-8_11"  => 31 Oct..8 Nov
  # - "30/12-02/01" => 30 Dec..2 Jan of the following year
  # - "31-02/01"    => 31 Dec (previous year)..2 Jan (a first day greater than the last
  #                    one, with an inherited month, belongs to the previous month)
  #
  # The caption year is assumed to be the year of the LAST date when the first part has
  # no explicit month (as in "31-02/01"), otherwise the year of the FIRST date.
  # Unparsable texts yield an instance with nil dates (#valid? false).
  #
  class RowDate
    DATE_REGEXP = %r{\A(?<d1>\d{1,2})(?:[/_.](?<m1>\d{1,2}))?(?:-(?<d2>\d{1,2})[/_.](?<m2>\d{1,2}))?\z}

    attr_reader :text, :year, :first_date, :last_date

    def self.parse(text, year)
      new(text, year)
    end

    def initialize(text, year)
      @text = text
      @year = year.to_s.strip.match?(/\A\d{4}\z/) ? year.to_i : nil
      @first_date, @last_date = compute_dates
    end

    def valid?
      first_date.present? && last_date.present?
    end

    # True when the (last) date of the row is before +today+.
    def past?(today = Date.current)
      valid? && last_date < today
    end

    private

    # Returns [first_date, last_date] or [nil, nil]
    def compute_dates
      parts = parse_parts
      return [nil, nil] unless parts && year && parts.last[1]

      parts.first[1] ? dates_from_first_year(*parts.first, *parts.last) : dates_from_last_year(parts.first[0], *parts.last)
    rescue Date::Error
      [nil, nil]
    end

    # Explicit first month: the caption year is the year of the first date.
    def dates_from_first_year(first_day, first_month, last_day, last_month)
      [Date.new(year, first_month, first_day), Date.new(last_month < first_month ? year + 1 : year, last_month, last_day)]
    end

    # Inherited first month: the caption year is the year of the last date; a first day greater
    # than the last one belongs to the previous month.
    def dates_from_last_year(first_day, last_day, last_month)
      last = Date.new(year, last_month, last_day)
      first_base = first_day > last_day ? last.prev_month : last
      [Date.new(first_base.year, first_base.month, first_day), last]
    end

    # Returns an Array of [day, month_or_nil] (1 or 2 items) or nil.
    def parse_parts
      match = text.to_s.gsub(/\s+/, '').match(DATE_REGEXP)
      return nil unless match

      parts = [[match[:d1].to_i, match[:m1]&.to_i]]
      parts << [match[:d2].to_i, match[:m2].to_i] if match[:d2]
      parts
    end
  end
end
