# frozen_string_literal: true

require 'json'

module SeasonBoard
  # = SeasonBoard::Backfill
  #
  #   - version:  7-0.10.73
  #   - author:   Steve A.
  #
  # One-time backfill linking the existing +calendars+ rows of a season to their FIN
  # calendar rows through the numeric FIN event ID (stored in <tt>calendars.results_code</tt>),
  # plus setting <tt>meetings.results_acquired</tt> for the season meetings that actually
  # have results (Data-Fix commits never set it before).
  #
  # No name matching is done against DB strings. The link is rebuilt from the archived files:
  #
  # 1. FIN ID per file "base" name: top-level +meetingURL+ / +manifestURL+ of each
  #    <tt>results.{done,new}/<season>/<base>.json</tt> (LT2 crawler output) or <tt><base>-lt4.json</tt>.
  # 2. Meeting ID per base: from the commit SQL file(s) <tt>NNNN-<base>-lt4.sql</tt> found under
  #    <tt>results.{sent,done,new}/<season></tt> (first meetings INSERT with explicit ID or meetings
  #    UPDATE; falls back to the +meeting_id+ of the calendars INSERT/UPDATE). The calendar IDs
  #    found in those files are collected too.
  # 3. Bases still without a FIN ID: the watcher snapshot rows (see FedernuotoWatch::StateStore)
  #    are used to predict the base name the CSV-mode crawler would have used
  #    (CrawlerCalendar::Row#manifest_basename); a predicted base having a commit SQL file
  #    takes the FIN ID from the snapshot row URL.
  #
  # Each season calendar row is then matched to the bases by calendar ID or meeting ID.
  #
  # The output is a list of idempotent UPDATE statements (rows already correct are skipped):
  # - calendars: +results_code+; +results_link+ when the current one is blank or not a FIN URL
  #   and a FIN results URL is known; +manifest_link+ when blank and known;
  # - meetings: +results_acquired+ for season meetings with at least one MIR/MRR and the flag false.
  #
  # == Modes
  # - simulate (default): nothing is written, neither to the DB nor to disk;
  # - apply (<tt>simulate: false</tt>): the same changes are run on the localhost DB inside a
  #   transaction and the SQL script is written to <tt>results.new/<season>/</tt> with the
  #   standard progressive numbering (see FileCounter), ready to be sent from the Push page.
  #
  # == Usage
  #   backfill = SeasonBoard::Backfill.new(season: season, simulate: true).call
  #   backfill.resolved    # => [{ calendar_id:, meeting_id:, fin_event_id:, fin_source:, meeting_source:, base:, changes: }]
  #   backfill.unresolved  # => [{ calendar_id:, meeting_id:, meeting_code:, scheduled_date:, reason:, candidates: }]
  #   backfill.statements  # => bare UPDATE statements
  #   backfill.sql_log     # => same, wrapped in a single transaction (with header)
  #   backfill.file_path   # => written script (apply mode only, when there's something to do)
  #   puts backfill.report
  #
  class Backfill # rubocop:disable Metrics/ClassLength
    include FileCounter

    DEFAULT_DATA_ROOT = Rails.root.join('crawler/data')
    SOURCE_DIRS = %w[results.done results.new].freeze
    SQL_DIRS = %w[results.sent results.done results.new].freeze
    SQL_FILE_REGEXP = /\A\d+-(.+)-lt4\.sql\z/
    # A single value of a SQL VALUES list: quoted string (with '' or \' escapes) or bare token.
    SQL_VALUE_REGEXP = /'(?:[^'\\]|\\.|'')*'|[^,\s][^,]*/m
    # Data files to be ignored when collecting bases (phase files, backups, ...):
    SKIPPED_JSON_REGEXP = /(-lt4-phase\d+|\.orig|\.bak\d*)\.json\z|\.json\.bak/

    attr_reader :season, :data_root, :simulate, :resolved, :unresolved, :statements, :sql_log, :file_path

    # == Params
    # - <tt>season</tt>: GogglesDb::Season instance;
    # - <tt>simulate</tt>: when +false+, applies the changes locally and writes the SQL script;
    # - <tt>data_root</tt>: crawler data root (default: 'crawler/data');
    # - <tt>snapshot_rows</tt>: watcher snapshot rows (Array of Hash with String keys
    #   'year', 'date', 'name', 'place', 'url'); default: read from FedernuotoWatch::StateStore.
    #
    def initialize(season:, simulate: true, data_root: DEFAULT_DATA_ROOT, snapshot_rows: nil)
      @season = season
      @simulate = simulate
      @data_root = Pathname.new(data_root)
      @snapshot_rows = snapshot_rows
      @resolved = []
      @unresolved = []
      @statements = []
      @sql_log = []
      @file_path = nil
    end

    # Scans files & DB, collects the statements and, when not simulating, applies them.
    # Returns the instance itself.
    def call
      bases = collect_bases
      resolve_calendars(bases)
      meeting_ids = meetings_to_flag
      build_statements(meeting_ids)
      apply!(meeting_ids) unless simulate || @statements.empty?
      self
    end

    # Human-readable report lines.
    def report # rubocop:disable Metrics/AbcSize
      lines = ["Season #{season.id} - #{simulate ? 'SIMULATE (nothing written)' : 'APPLY'}"]
      lines << "Resolved: #{@resolved.size} calendar rows"
      @resolved.each do |row|
        changes = row[:changes].present? ? row[:changes].keys.join(', ') : 'already up to date'
        lines << format('  calendar %<cal>-6s meeting %<mtg>-7s FIN %<fin>-8s via %<how>-28s %<chg>s [%<base>s]',
                        cal: row[:calendar_id], mtg: row[:meeting_id], fin: row[:fin_event_id],
                        how: "#{row[:fin_source]}+#{row[:meeting_source]}", chg: changes, base: row[:base])
      end
      lines << "Unresolved: #{@unresolved.size} calendar rows"
      @unresolved.each do |row|
        lines << "  calendar #{row[:calendar_id]} meeting #{row[:meeting_id]} (#{row[:meeting_code]}, " \
                 "#{row[:scheduled_date]}): #{row[:reason]}"
        row[:candidates].each do |cand|
          lines << "      same-date FIN row: #{cand[:fin_event_id]} - #{cand[:name]} (#{cand[:place]})"
        end
      end
      lines << "Meetings to flag as results_acquired: #{@flagged_meeting_ids.to_a.inspect}"
      lines << "Statements: #{@statements.size}"
      lines << "SQL file: #{@file_path}" if @file_path
      lines
    end

    private

    # == Base collection =====================================================

    # Base info: { fin_event_id:, results_url:, manifest_url:, fin_source:, meeting_id:, meeting_source:, calendar_ids: }
    def collect_bases
      bases = Hash.new { |h, k| h[k] = { calendar_ids: [] } }
      collect_sql_info(bases)
      collect_file_urls(bases)
      collect_snapshot_urls(bases)
      bases
    end

    def season_path(dir)
      data_root.join(dir, season.id.to_s)
    end

    def collect_sql_info(bases)
      sql_files = SQL_DIRS.flat_map { |dir| Dir.glob(season_path(dir).join('*.sql').to_s) }
      sql_files.sort_by { |path| File.basename(path) }.each do |path|
        base = File.basename(path)[SQL_FILE_REGEXP, 1]
        next unless base

        parse_commit_sql(File.read(path, encoding: 'UTF-8'), bases[base])
      end
    end

    # Scans a commit SQL file, filling meeting_id/meeting_source/calendar_ids of the base info.
    def parse_commit_sql(sql, info)
      meeting_id = sql[/INSERT INTO `meetings` \(`id`,[^)]*\)\s*VALUES \((\d+),/m, 1] ||
                   sql[/UPDATE `meetings`\s+SET .*?\s+WHERE \(?`id`\s*=\s*(\d+)\)?;/m, 1]
      if meeting_id && info[:meeting_id].nil?
        info[:meeting_id] = meeting_id.to_i
        info[:meeting_source] = :meetings_sql
      end

      calendar_insert_rows(sql).each do |cols|
        info[:calendar_ids] |= [cols['id'].to_i] if cols['id']
        assign_calendar_meeting(info, cols['meeting_id'])
      end
      sql.scan(/UPDATE `calendars`\s+SET (.*?)\s+WHERE \(?`id`\s*=\s*(\d+)\)?;/m).each do |sets, cal_id|
        info[:calendar_ids] |= [cal_id.to_i]
        assign_calendar_meeting(info, sets[/`meeting_id`=(\d+)/, 1])
      end
    end

    def assign_calendar_meeting(info, meeting_id)
      return if meeting_id.to_i.zero? || info[:meeting_id]

      info[:meeting_id] = meeting_id.to_i
      info[:meeting_source] = :calendars_sql
    end

    # Returns an Array of { column => raw value } Hashes, one for each calendars INSERT.
    def calendar_insert_rows(sql)
      sql.scan(/INSERT INTO `calendars` \(([^)]*)\)\s*VALUES \((.*?)\);\s*$/m).map do |cols, values|
        names = cols.scan(/`([^`]+)`/).flatten
        names.zip(split_sql_values(values)).to_h
      end
    end

    # Splits a SQL VALUES list on the commas outside single-quoted strings (both '' and \' escapes),
    # returning the raw tokens (quotes removed from string literals).
    def split_sql_values(values)
      values.scan(SQL_VALUE_REGEXP).map { |token| token.strip.delete_prefix("'").delete_suffix("'") }
    end

    # Reads the FIN URLs from the crawl/working-copy data files of each base.
    def collect_file_urls(bases)
      json_files = SOURCE_DIRS.flat_map { |dir| Dir.glob(season_path(dir).join('*.json').to_s) }
      json_files.sort.each do |path|
        name = File.basename(path)
        next if name.match?(SKIPPED_JSON_REGEXP)

        base = name.delete_suffix('.json').delete_suffix('-lt4')
        data = read_json_head(path)
        next unless data

        assign_urls(bases[base], data['meetingURL'], data['manifestURL'], :source_file)
      end
    end

    def read_json_head(path)
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def assign_urls(info, meeting_url, manifest_url, source)
      fin_id = FINEventId.parse_any(meeting_url, manifest_url)
      return unless fin_id
      return if info[:fin_event_id] && info[:fin_event_id] != fin_id

      info[:fin_event_id] ||= fin_id
      info[:fin_source] ||= source
      info[:results_url] ||= meeting_url if FINEventId.from_results_url(meeting_url)
      assign_manifest_url(info, manifest_url)
    end

    def assign_manifest_url(info, manifest_url)
      info[:manifest_url] ||= manifest_url if FINEventId.from_manifest_url(manifest_url)
    end

    # Fills the bases still lacking a FIN ID (and having a commit SQL) through the predicted
    # snapshot basenames.
    def collect_snapshot_urls(bases)
      snapshot_by_base = snapshot_rows.each_with_object({}) do |row, memo|
        next unless FINEventId.parse(row['url'])

        csv_row = row.slice('year', 'date', 'name', 'place').merge('meetingUrl' => row['url'])
        predicted = CrawlerCalendar::Row.new(csv_row:, index: 0, season_id: season.id, data_root:).manifest_basename
        memo[predicted] ||= row
      end

      bases.each do |base, info|
        next if info[:fin_event_id] || info[:meeting_id].nil?

        row = snapshot_by_base[base]
        assign_urls(info, row['url'], nil, :snapshot) if row
      end
    end

    def snapshot_rows
      @snapshot_rows ||= Array(FedernuotoWatch::StateStore.new.read['rows'])
    end

    # Snapshot row URL (if any) for the given FIN ID.
    def snapshot_url_for(fin_id)
      snapshot_rows.find { |row| FINEventId.from_results_url(row['url']) == fin_id }&.dig('url')
    end

    # == Calendar matching ===================================================

    def season_calendars
      @season_calendars ||= GogglesDb::Calendar.unscoped.where(season_id: season.id).order(:id).to_a
    end

    def resolve_calendars(bases)
      linked = bases.select { |_base, info| info[:fin_event_id] && (info[:meeting_id] || info[:calendar_ids].any?) }
      season_calendars.each do |calendar|
        matches = linked.select do |_base, info|
          info[:calendar_ids].include?(calendar.id) || (calendar.meeting_id && info[:meeting_id] == calendar.meeting_id)
        end
        resolve_calendar(calendar, matches)
      end
      detect_duplicate_codes
    end

    def resolve_calendar(calendar, matches)
      fin_ids = matches.values.pluck(:fin_event_id).uniq
      if fin_ids.size > 1
        add_unresolved(calendar, "conflicting FIN ids #{fin_ids.join(', ')} from #{matches.keys.join(', ')}")
      elsif fin_ids.one?
        base, info = matches.first
        add_resolved(calendar, base, info)
      elsif calendar.results_code.present?
        add_resolved(calendar, nil, fin_event_id: calendar.results_code, fin_source: :existing, meeting_id: calendar.meeting_id)
      else
        add_unresolved(calendar, unresolved_reason(calendar))
      end
    end

    def add_resolved(calendar, base, info)
      fin_id = info[:fin_event_id]
      results_url = info[:results_url] || snapshot_url_for(fin_id)
      @resolved << {
        calendar_id: calendar.id, meeting_id: calendar.meeting_id || info[:meeting_id], fin_event_id: fin_id,
        fin_source: info[:fin_source], meeting_source: info[:meeting_source] || :calendar_row, base:,
        changes: calendar_changes(calendar, fin_id, results_url, info[:manifest_url])
      }
    end

    def calendar_changes(calendar, fin_id, results_url, manifest_url)
      changes = {}
      changes['results_code'] = fin_id if calendar.results_code.to_s != fin_id
      if results_url.present? && calendar.results_link != results_url &&
         (calendar.results_link.blank? || !FINEventId.fin_url?(calendar.results_link))
        changes['results_link'] = results_url
      end
      changes['manifest_link'] = manifest_url if manifest_url.present? && calendar.manifest_link.blank?
      changes
    end

    def add_unresolved(calendar, reason)
      @unresolved << {
        calendar_id: calendar.id, meeting_id: calendar.meeting_id, meeting_code: calendar.meeting_code,
        scheduled_date: calendar.scheduled_date, reason:, candidates: same_date_candidates(calendar)
      }
    end

    def unresolved_reason(calendar)
      return 'no meeting linked' if calendar.meeting_id.nil?

      'no FIN id found in the source files nor through the snapshot-predicted file names'
    end

    # Snapshot rows (with a FIN ID) starting on the calendar scheduled date, as hints for a manual link.
    def same_date_candidates(calendar)
      date = calendar.scheduled_date.to_s
      snapshot_rows.filter_map do |row|
        fin_id = FINEventId.parse(row['url'])
        next unless fin_id && CrawlerCalendar::Row.parse_days_date(row['date'], row['year']).first == date

        { fin_event_id: fin_id, name: row['name'], place: row['place'], url: row['url'] }
      end
    end

    # The same FIN ID resolved for 2+ calendar rows: none of them is safe to update.
    def detect_duplicate_codes
      dups = @resolved.group_by { |row| row[:fin_event_id] }.select { |_id, rows| rows.size > 1 }
      dups.each do |fin_id, rows|
        rows.each do |row|
          @resolved.delete(row)
          calendar = season_calendars.find { |cal| cal.id == row[:calendar_id] }
          add_unresolved(calendar, "FIN id #{fin_id} resolved for several calendar rows")
        end
      end
    end

    # == Meetings ============================================================

    # IDs of season meetings with at least one MIR/MRR and results_acquired still false.
    def meetings_to_flag
      candidates = GogglesDb::Meeting.unscoped.where(season_id: season.id, results_acquired: false).pluck(:id)
      return @flagged_meeting_ids = [] if candidates.empty?

      with_results = [GogglesDb::MeetingIndividualResult, GogglesDb::MeetingRelayResult].flat_map do |klass|
        klass.unscoped.joins(meeting_program: { meeting_event: :meeting_session })
             .where(meeting_sessions: { meeting_id: candidates })
             .distinct.pluck('meeting_sessions.meeting_id')
      end
      @flagged_meeting_ids = with_results.uniq.sort
    end

    # == SQL =================================================================

    def build_statements(meeting_ids)
      @resolved.each do |row|
        next if row[:changes].blank?

        calendar = season_calendars.find { |cal| cal.id == row[:calendar_id] }
        @statements << SqlMaker.new(row: calendar).log_update(row[:changes].merge('updated_at' => nil))
      end
      meeting_ids.each do |meeting_id|
        meeting = GogglesDb::Meeting.unscoped.find(meeting_id)
        @statements << SqlMaker.new(row: meeting).log_update('results_acquired' => true, 'updated_at' => nil)
      end
      @sql_log = wrap_statements
    end

    def wrap_statements
      return [] if @statements.empty?

      [
        "-- Season board backfill: season_id=#{season.id} (calendars.results_code/links & meetings.results_acquired)\r\n",
        'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";',
        'SET AUTOCOMMIT = 0;',
        'START TRANSACTION;',
        "--\r\n",
        *@statements,
        "\r\n--\r\n",
        'COMMIT;'
      ]
    end

    def apply!(meeting_ids)
      ActiveRecord::Base.transaction do
        @resolved.each do |row|
          next if row[:changes].blank?

          season_calendars.find { |cal| cal.id == row[:calendar_id] }.update!(row[:changes])
        end
        GogglesDb::Meeting.unscoped.where(id: meeting_ids).find_each { |meeting| meeting.update!(results_acquired: true) }
        # Written inside the transaction: on failure no script exists without its local changes.
        write_sql_file
      end
    end

    def write_sql_file
      source_dir = season_path('results.new')
      sent_dir = season_path('results.sent')
      FileUtils.mkdir_p(source_dir)
      counter = compute_file_counter(source_dir, sent_dir)
      @file_path = source_dir.join("#{format('%04d', counter + 1)}-season_board_backfill-#{season.id}.sql")
      File.write(@file_path, "#{@sql_log.join("\r\n")}\r\n")
    end
  end
end
