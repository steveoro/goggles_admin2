# frozen_string_literal: true

module SeasonBoard
  # = SeasonBoard::CalendarLinker
  #
  #   - version:  7-0.10.73
  #   - author:   Steve A.
  #
  # Manual "link this FIN calendar row to this existing calendar/meeting" action, for the
  # calendar rows left unresolved by SeasonBoard::Backfill (or any later leftover).
  #
  # Sets <tt>calendars.results_code</tt> to the FIN event ID (plus +results_link+ / +manifest_link+
  # when given: an existing FIN +results_link+ is never replaced by a non-FIN URL; +manifest_link+
  # is set only when blank; a calendar already carrying a different FIN event ID is refused) on the
  # localhost DB inside a transaction, writing at the same time the
  # replayable SQL script to <tt>results.new/<season>/</tt> with the standard progressive numbering
  # (same pattern as TeamManagerSqlCreate).
  #
  # == Usage
  #   result = SeasonBoard::CalendarLinker.new(season:, calendar_id: 1697, fin_event_id: '150100',
  #                                            results_link: url).call
  #   result.success?  # => true/false
  #   result.sql_path  # => written script (nil when nothing changed or on failure)
  #   result.error     # => error message, on failure
  #
  class CalendarLinker
    include FileCounter

    # Outcome of #call.
    Result = Struct.new(:success, :sql_path, :error, keyword_init: true) do
      def success?
        success
      end
    end

    attr_reader :season, :calendar_id, :fin_event_id, :results_link, :manifest_link, :data_root

    # == Params
    # - <tt>season</tt>: GogglesDb::Season (or its ID);
    # - <tt>calendar_id</tt>: ID of the season calendar row to be linked;
    # - <tt>fin_event_id</tt>: numeric FIN event ID (String or Integer);
    # - <tt>results_link</tt>, <tt>manifest_link</tt>: optional FIN URLs;
    # - <tt>data_root</tt>: crawler data root (default: 'crawler/data').
    #
    def initialize(season:, calendar_id:, fin_event_id:, results_link: nil, manifest_link: nil, # rubocop:disable Metrics/ParameterLists
                   data_root: Backfill::DEFAULT_DATA_ROOT)
      @season = season.is_a?(GogglesDb::Season) ? season : GogglesDb::Season.find_by(id: season)
      @calendar_id = calendar_id.to_i
      @fin_event_id = fin_event_id.to_s.strip.sub(/\A0+/, '')
      @results_link = results_link.presence
      @manifest_link = manifest_link.presence
      @data_root = Pathname.new(data_root)
    end

    # Validates, updates the row locally and writes the SQL script. Returns a Result.
    def call
      error = validation_error
      return Result.new(success: false, error:) if error

      changes = calendar_changes
      return Result.new(success: true) if changes.empty?

      sql_path = nil
      ActiveRecord::Base.transaction do
        sql = SqlMaker.new(row: @calendar).log_update(changes.merge('updated_at' => nil))
        @calendar.update!(changes)
        # Written inside the transaction: on failure no script exists without its local change.
        sql_path = write_sql_file(sql)
      end
      Result.new(success: true, sql_path:)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end

    private

    def validation_error
      return 'Season not found' unless season
      return "Invalid FIN event id '#{fin_event_id}'" unless fin_event_id.match?(/\A\d+\z/)

      @calendar = GogglesDb::Calendar.unscoped.find_by(id: calendar_id)
      return "Calendar #{calendar_id} not found" unless @calendar
      return "Calendar #{calendar_id} does not belong to season #{season.id}" unless @calendar.season_id == season.id

      link_conflict_error
    end

    # Error message when the calendar already carries another FIN event id (never overwritten) or
    # another season calendar already uses this FIN event id; nil otherwise.
    def link_conflict_error
      current_code = @calendar.results_code.to_s.strip.sub(/\A0+/, '')
      return "Calendar #{calendar_id} is already linked to FIN event id #{current_code}" if current_code.present? && current_code != fin_event_id

      duplicate = GogglesDb::Calendar.unscoped.where(season_id: season.id, results_code: fin_event_id)
                                     .where.not(id: calendar_id).pick(:id)
      "FIN event id #{fin_event_id} is already linked to calendar #{duplicate}" if duplicate
    end

    def calendar_changes
      changes = {}
      changes['results_code'] = fin_event_id if @calendar.results_code.to_s != fin_event_id
      changes['results_link'] = results_link if replace_results_link?
      changes['manifest_link'] = manifest_link if manifest_link && @calendar.manifest_link.blank?
      changes
    end

    # True when the given results_link should be stored: an existing FIN link is never
    # replaced by a non-FIN one.
    def replace_results_link?
      return false if results_link.nil? || @calendar.results_link == results_link
      return true if @calendar.results_link.blank? || FINEventId.fin_url?(results_link)

      !FINEventId.fin_url?(@calendar.results_link)
    end

    def write_sql_file(sql)
      source_dir = data_root.join('results.new', season.id.to_s)
      sent_dir = data_root.join('results.sent', season.id.to_s)
      FileUtils.mkdir_p(source_dir)
      counter = compute_file_counter(source_dir, sent_dir)
      file_path = source_dir.join("#{format('%04d', counter + 1)}-calendar_link-#{@calendar.id}-#{fin_event_id}.sql")
      lines = [
        "-- Season board manual link: season_id=#{season.id}, calendar_id=#{@calendar.id}, FIN event #{fin_event_id}\r\n",
        'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";',
        'SET AUTOCOMMIT = 0;',
        'START TRANSACTION;',
        "--\r\n",
        sql,
        "\r\n--\r\n",
        'COMMIT;'
      ]
      File.write(file_path, "#{lines.join("\r\n")}\r\n")
      file_path
    end
  end
end
