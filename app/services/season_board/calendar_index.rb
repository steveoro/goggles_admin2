# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CalendarIndex
  #
  # The meeting links of the FIN "Eventi" calendar (0.10.102), lent to the Season board rows whose
  # "Riepilogo Eventi" row (the watcher snapshot) has no link yet.
  #
  # The "Eventi" calendar is crawled from Sources (crawler tab, FIN calendar, sub-menu 'Eventi') into
  # <tt>calendar.new/<season>/<YYYYMMDD>-<season>-2-FIN-calendar.csv</tt> (moved to <tt>calendar.done/<season></tt> once
  # its meetings were crawled) and carries a meeting link for every row. Nothing is stored: the links are derived
  # again at every board build.
  #
  # == The calendar file (all required, else no index at all and one warning saying why)
  # - only the NEWEST original file of the season across both folders is read (by the name date, then the mtime;
  #   never a <tt>-sel-</tt> selection or a <tt>-skip</tt> leftover): an older file is never used in its place;
  # - it parses (CrawlerCalendar::Sheet) with the expected columns and at least one data row;
  # - it is the 'Eventi' calendar: the startURL of every row is EVENTI_START_URL (the 'Archivio' sub-menu writes the
  #   same file name with its archive page there; 'Riepilogo Eventi' writes '-3-FIN-current-meetings.csv');
  # - every readable row date falls within the board season dates (+/- SEASON_MARGIN): the season id is the
  #   operator's choice on the crawler tab;
  # - its name date is at most MAX_FILE_AGE older than the last watcher check (+as_of+): a stale calendar could lend
  #   the id of a postponed meeting to a new one on the same day and place.
  #
  # == Matching key (names differ between the two pages, so they are never compared)
  # [first date, last date, normalized place set]:
  # - CSV dates: the ';'-separated ISO dates of the row, min and max (a FIN day text such as '21-22/11' goes
  #   through SeasonBoard::RowDate with the CSV year); watcher dates: SeasonBoard::RowDate with the table year;
  # - places: each ';'-separated place without its province suffix ('Napoli (NA)', 'Ostia - RM'), transliterated,
  #   downcased, punctuation turned into spaces, spaces squeezed; the set sorted. A row whose dates or places can't be
  #   read has no key (it never matches).
  #
  # == Adoption (all required)
  # - exactly one CSV row and exactly one watcher row share the key;
  # - the watcher row has no URL; the CSV row is not cancelled and its meetingUrl is a FIN results URL
  #   (FINEventId.from_results_url on a federnuoto.it address: never a manifest download link);
  # - that FIN id appears once in the whole file (cancelled and keyless rows included) and is on no watcher row;
  # - self-check: among the keys shared one-to-one by rows that BOTH have a FIN id, at most MAX_DISAGREEMENT_RATIO
  #   disagree, and there are at least MIN_COMPARABLE of them (fewer can't tell a working key from a broken one).
  #   Otherwise nothing is adopted and #warnings says why.
  # A watcher row that has its own link always keeps it: when the CSV row of its key carries another FIN id,
  # #warnings names both (the summary page link is used).
  #
  # == API (+rows+: the watcher snapshot rows, Hashes with String keys; the outcome is memoized per rows Array)
  # - #link_for(watcher_row, rows)  => Link (url, fin_event_id, name, calendar_date, file_name) or nil
  # - #url_for(fin_event_id, rows)  => the adopted URL of the FIN id, or nil (MeetingCrawlJob)
  # - #adopted_fin_event_ids(rows)  => Array of Strings
  # - #warnings(rows = nil)         => Array of Strings (localized): why the file was refused, plus the self-check
  #                                    and mismatch notes for +rows+
  # - #file_path / #calendar_date / #available?
  # Never raises on file content (a bad row is skipped, a bad file refused): no index = no adoption.
  #
  class CalendarIndex # rubocop:disable Metrics/ClassLength
    CALENDAR_FOLDERS = %w[calendar.new calendar.done].freeze

    # startURL written by crawler/server/calendar-crawler.js for the 'Eventi' sub-menu (processPage, layout 2).
    EVENTI_START_URL = 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html'

    # A calendar file whose name date is older than the last watcher check by more than this lends nothing
    # (step 6 adds a daily 'Eventi' crawl that keeps it fresh).
    MAX_FILE_AGE = 14.days
    # Tolerance on the season dates for the rows of the calendar file.
    SEASON_MARGIN = 15.days

    # Fewer comparable keys than this: the self-check can't judge, nothing is adopted.
    MIN_COMPARABLE = 3
    # More than this share of the comparable keys disagreeing on the FIN id: nothing is adopted.
    MAX_DISAGREEMENT_RATIO = 0.10

    # CSV columns the index needs.
    REQUIRED_HEADERS = %w[startURL date place meetingUrl].freeze

    # Province suffixes: 'Napoli (NA)', 'San Marino (RSM)', 'Ostia - RM'.
    PROVINCE_SUFFIX_REGEXP = /\s*\(\s*[[:alpha:]]{2,3}\s*\)\s*\z/
    DASH_PROVINCE_SUFFIX_REGEXP = /\s+-\s+[[:upper:]]{2}\z/

    # The link lent to a watcher row: the CSV meetingUrl, its FIN id, the CSV row name, the date of the calendar
    # file (from its name) and the file base name.
    Link = Data.define(:url, :fin_event_id, :name, :calendar_date, :file_name)

    # One CSV row with a key.
    Entry = Data.define(:key, :fin_event_id, :url, :name, :cancelled)

    # One parsed CSV row (key nil when unreadable); start_url: the row's startURL.
    Parsed = Data.define(:entry, :fin_event_id, :start_url, :first_date, :last_date)

    # Outcome of the matching for one rows Array.
    # - links: key => Link; comparable / disagreements: counts of the self-check; suspended: self-check failed;
    # - warnings: localized Strings.
    Resolution = Data.define(:links, :comparable, :disagreements, :suspended, :warnings) do
      def self.empty(warnings: []) = new(links: {}, comparable: 0, disagreements: 0, suspended: false, warnings:)
    end

    attr_reader :season_id, :data_dir, :file_path, :calendar_date

    # File name of an original 'Eventi' calendar CSV of the season (MatchData[:date] = YYYYMMDD).
    def self.file_regexp(season_id)
      /\A(?<date>\d{8})-#{Regexp.escape(season_id.to_s)}-2-FIN-calendar\.csv\z/
    end

    # The original 'Eventi' calendar CSVs of the season in calendar.new / calendar.done, newest first (name date,
    # then mtime). No content is read (also used by Snapshot::Fingerprint).
    def self.candidate_paths(season_id, data_dir: nil)
      base = Pathname.new(data_dir || DiskIndex.default_data_dir)
      regexp = file_regexp(season_id)
      paths = CALENDAR_FOLDERS.flat_map do |folder|
        dir = base.join(folder, season_id.to_s)
        dir.directory? ? dir.children.select { |path| regexp.match?(path.basename.to_s) && path.file? } : []
      end
      paths.sort_by { |path| [path.basename.to_s[0, 8], mtime_of(path)] }.reverse
    rescue SystemCallError
      []
    end

    def self.mtime_of(path)
      File.mtime(path).to_f
    rescue SystemCallError
      0.0
    end

    # Matching key of a watcher snapshot row (or nil).
    def self.watcher_key(row)
      date = RowDate.parse(row['date'], row['year'])
      places = normalize_places(row['place'])
      date.valid? && places.any? ? [date.first_date, date.last_date, places] : nil
    end

    # Matching key of a CrawlerCalendar::Row (or nil).
    def self.csv_key(csv_row)
      first_date, last_date = csv_dates(csv_row.date, csv_row.year)
      places = normalize_places(csv_row.place)
      first_date && places.any? ? [first_date, last_date, places] : nil
    end

    # [min, max] of the ';'-separated ISO dates of a CSV cell, else of its FIN day text read with +year+; [nil, nil]
    # when neither works (also for a cell longer than the Date parser accepts, an ArgumentError).
    def self.csv_dates(text, year)
      dates = text.to_s.split(';').map(&:strip).compact_blank.map { |value| Date.iso8601(value) }
      dates.any? ? dates.minmax : [nil, nil]
    rescue ArgumentError
      row_date = RowDate.parse(text, year)
      row_date.valid? ? [row_date.first_date, row_date.last_date] : [nil, nil]
    end

    # Sorted, unique Array of the normalized places of a place cell (';'-separated).
    def self.normalize_places(text)
      text.to_s.split(';').filter_map { |place| normalize_place(place).presence }.uniq.sort
    end

    def self.normalize_place(text)
      place = text.to_s.strip.sub(PROVINCE_SUFFIX_REGEXP, '').sub(DASH_PROVINCE_SUFFIX_REGEXP, '')
      ActiveSupport::Inflector.transliterate(place).downcase.gsub(/[^a-z0-9]+/, ' ').squeeze(' ').strip
    end

    # FIN event id of a CSV meetingUrl: a results page URL on the FIN site only (never a manifest download link).
    def self.results_fin_event_id(url)
      FINEventId.fin_url?(url) ? FINEventId.from_results_url(url) : nil
    end

    # == Params
    # - season: the board season (GogglesDb::Season, or anything with #id, #begin_date & #end_date);
    # - data_dir: base 'crawler/data' folder (default: DiskIndex.default_data_dir);
    # - as_of: time of the last watcher check ('last_checked' of the snapshot; default: today), for MAX_FILE_AGE.
    def initialize(season:, data_dir: nil, as_of: nil)
      @season = season
      @season_id = season.id.to_s
      @data_dir = Pathname.new(data_dir || DiskIndex.default_data_dir)
      @as_of = (as_of || Date.current).to_date
      @load_warnings = []
      @id_counts = Hash.new(0)
      @entries = load_entries
    end

    # True when a calendar file was accepted.
    def available? = !file_path.nil?

    # The Link adopted by the watcher row, or nil.
    def link_for(watcher_row, rows)
      return nil if !watcher_row.is_a?(Hash) || watcher_row['url'].present?

      key = safe_watcher_key(watcher_row)
      key && resolve(rows).links[key]
    end

    # The adopted URL of the FIN id among +rows+, or nil.
    def url_for(fin_event_id, rows)
      id = fin_event_id.to_s
      resolve(rows).links.each_value.find { |link| link.fin_event_id == id }&.url
    end

    def adopted_fin_event_ids(rows)
      resolve(rows).links.values.map(&:fin_event_id)
    end

    # Localized warnings: why the calendar file was refused, plus the self-check & mismatch notes for +rows+.
    def warnings(rows = nil)
      @load_warnings + (rows.nil? ? [] : resolve(rows).warnings)
    end

    # The Resolution for +rows+ (memoized for the last rows Array, by identity). Never raises.
    def resolve(rows)
      return @resolution if @resolution && @resolved_rows.equal?(rows)

      @resolved_rows = rows
      @resolution = @entries.empty? ? Resolution.empty : compute(Array(rows).grep(Hash))
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::CalendarIndex] matching failed: #{e.class}: #{e.message}")
      @resolution = Resolution.empty(warnings: [refusal(:unreadable, error: "#{e.class}: #{e.message}".truncate(120))])
    end

    private

    def compute(rows)
      pairs = one_to_one_pairs(rows)
      comparable, disagreeing = self_check(pairs)
      candidates = adoptable(pairs, rows)
      suspended = comparable.size < MIN_COMPARABLE || disagreeing.size > comparable.size * MAX_DISAGREEMENT_RATIO
      links = suspended ? {} : candidates.to_h { |entry, _row| [entry.key, link_of(entry)] }
      Resolution.new(links:, comparable: comparable.size, disagreements: disagreeing.size, suspended:,
                     warnings: resolution_warnings(comparable, disagreeing, candidates))
    end

    # [comparable, disagreeing]: the pairs where both rows have a FIN id ([entry, row, watcher FIN id]), and those of
    # them with two different ids.
    def self_check(pairs)
      comparable = pairs.filter_map do |entry, row|
        watcher_id = FINEventId.parse(row['url'])
        [entry, row, watcher_id] if watcher_id && entry.fin_event_id
      end
      [comparable, comparable.reject { |entry, _row, watcher_id| entry.fin_event_id == watcher_id }]
    end

    # [Entry, watcher row] for every key shared by exactly one CSV row and exactly one watcher row.
    def one_to_one_pairs(rows)
      by_key = rows.group_by { |row| safe_watcher_key(row) }
      by_key.delete(nil)
      @entries.group_by(&:key).filter_map do |key, entries|
        watcher_rows = by_key[key]
        [entries.first, watcher_rows.first] if entries.one? && watcher_rows&.one?
      end
    end

    # The pairs whose watcher row has no URL and whose CSV row can lend its FIN id (#lendable?).
    def adoptable(pairs, rows)
      watcher_ids = rows.filter_map { |row| FINEventId.parse(row['url']) }.to_set
      pairs.select { |entry, row| row['url'].blank? && lendable?(entry, watcher_ids) }
    end

    # A CSV row not cancelled, whose FIN id appears once in the whole file and on no watcher row.
    def lendable?(entry, watcher_ids)
      !entry.cancelled && entry.fin_event_id.present? && @id_counts[entry.fin_event_id] == 1 &&
        watcher_ids.exclude?(entry.fin_event_id)
    end

    def safe_watcher_key(row)
      self.class.watcher_key(row)
    rescue StandardError
      nil
    end

    def resolution_warnings(comparable, disagreeing, candidates)
      file = file_path.basename.to_s
      if comparable.size >= MIN_COMPARABLE && disagreeing.size > comparable.size * MAX_DISAGREEMENT_RATIO
        return [I18n.t('season_board.calendar_links.suspended', file:, count: disagreeing.size, total: comparable.size)]
      end

      warnings = disagreeing.map { |entry, row, watcher_id| mismatch_warning(entry, row, watcher_id) }
      if comparable.size < MIN_COMPARABLE && candidates.any?
        warnings << I18n.t('season_board.calendar_links.too_few', file:, total: comparable.size, min: MIN_COMPARABLE,
                                                                  count: candidates.size)
      end
      warnings
    end

    def mismatch_warning(entry, row, watcher_id)
      I18n.t('season_board.calendar_links.mismatch', watcher_id:, calendar_id: entry.fin_event_id,
                                                     date: row['date'], place: row['place'], file: file_path.basename.to_s)
    end

    def link_of(entry)
      Link.new(url: entry.url, fin_event_id: entry.fin_event_id, name: entry.name, calendar_date:, file_name: file_path.basename.to_s)
    end

    # == Loading

    # Entries of the newest calendar file when it passes every check (sets #file_path / #calendar_date), else []
    # with one warning.
    def load_entries
      path = self.class.candidate_paths(@season_id, data_dir: @data_dir).first
      return [] unless path

      @file = path.basename.to_s
      parsed = parse_file(path)
      return [] unless parsed && accepted?(path, parsed)

      @file_path = path
      @calendar_date = date_of(path)
      parsed.each { |row| @id_counts[row.fin_event_id] += 1 if row.fin_event_id }
      parsed.filter_map(&:entry)
    end

    # Parsed rows of the file, or nil (with a warning) when it can't be read or has no data row.
    def parse_file(path)
      sheet = CrawlerCalendar::Sheet.new(path, season_id: @season_id, data_root: @data_dir)
      missing = REQUIRED_HEADERS - Array(sheet.headers).compact
      raise ArgumentError, "missing columns #{missing.join(', ')}" if missing.any?
      raise ArgumentError, 'no data rows' if sheet.row_count.zero?

      sheet.rows.map { |csv_row| parse_row(csv_row) }
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::CalendarIndex] #{path}: #{e.class}: #{e.message}")
      refuse!(:unreadable, error: "#{e.class}: #{e.message}".truncate(120))
    end

    # One row, never raising: a row that can't be read gets no key and no FIN id (it never lends anything).
    def parse_row(csv_row)
      start_url = csv_row.csv_row['startURL'].to_s.strip
      url = csv_row.url.strip.presence if csv_row.url?
      fin_event_id = self.class.results_fin_event_id(url)
      entry, first_date, last_date = entry_of(csv_row, fin_event_id, url)
      Parsed.new(entry:, fin_event_id:, start_url:, first_date:, last_date:)
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::CalendarIndex] #{@file} row #{csv_row.index + 2}: #{e.class}: #{e.message}")
      # (the FIN id read before the failure still counts for the uniqueness rule)
      Parsed.new(entry: nil, fin_event_id:, start_url: start_url.to_s, first_date: nil, last_date: nil)
    end

    # [Entry (nil without readable dates & places), first date, last date] of a row.
    def entry_of(csv_row, fin_event_id, url)
      first_date, last_date = self.class.csv_dates(csv_row.date, csv_row.year)
      places = self.class.normalize_places(csv_row.place)
      entry = (Entry.new(key: [first_date, last_date, places], fin_event_id:, url:, name: csv_row.name, cancelled: csv_row.cancelled?) if first_date && places.any?)
      [entry, first_date, last_date]
    end

    # True when the file is the 'Eventi' calendar of the board season and is recent enough (else a warning).
    def accepted?(path, parsed)
      foreign = parsed.index { |row| row.start_url != EVENTI_START_URL }
      return refuse!(:not_eventi, row: foreign + 2, url: parsed[foreign].start_url.truncate(100)) if foreign

      outside = parsed.index { |row| outside_season?(row) }
      return refuse!(:outside_season, row: outside + 2, date: parsed[outside].first_date.to_s) if outside

      date = date_of(path)
      return true if date >= @as_of - MAX_FILE_AGE

      refuse!(:too_old, date: date.strftime('%d/%m/%Y'), days: MAX_FILE_AGE.in_days.to_i)
    end

    def outside_season?(row)
      return false unless row.first_date && @season.respond_to?(:begin_date) && @season.begin_date && @season.end_date

      row.first_date < @season.begin_date - SEASON_MARGIN || row.last_date > @season.end_date + SEASON_MARGIN
    end

    # Records the refusal warning; returns nil / false (no index).
    def refuse!(reason, **params)
      @load_warnings << refusal(reason, **params)
      nil
    end

    def refusal(reason, **params)
      I18n.t("season_board.calendar_links.#{reason}", file: @file, season: @season_id, **params)
    end

    # Date of the file name (YYYYMMDD), else of its mtime.
    def date_of(path)
      Date.strptime(path.basename.to_s[0, 8], '%Y%m%d')
    rescue Date::Error
      File.mtime(path).to_date
    end
  end
end
