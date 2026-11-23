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
  # replayable SQL script to <tt>results.new/<season>/</tt> through Outbox::Writer (kind 'calendar_link',
  # global sequence numbering; same pattern as TeamManagerSqlCreate).
  #
  # == Usage
  #   result = SeasonBoard::CalendarLinker.new(season:, calendar_id: 1697, fin_event_id: '150100',
  #                                            results_link: url).call
  #   result.success?  # => true/false
  #   result.sql_path  # => written script (nil when nothing changed or on failure)
  #   result.error     # => error message, on failure
  #
  class CalendarLinker
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

      script = nil
      committed = false
      ActiveRecord::Base.transaction do
        sql = SqlMaker.new(row: @calendar).log_update(changes.merge('updated_at' => nil))
        @calendar.update!(changes)
        # Written inside the transaction: on failure no script exists without its local change.
        script = write_sql_file(sql)
      end
      committed = true
      record_link_event(changes, script.absolute_path)
      Result.new(success: true, sql_path: script.absolute_path)
    rescue StandardError => e
      # (the local change rolled back: a script written meanwhile must not stay pushable)
      Outbox::Writer.discard!(@script) unless committed
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

    # Appends 'board.calendar_linked' to the ops event log (never raises).
    def record_link_event(changes, sql_path)
      Ops.safely do
        Ops.record_event!(
          kind: 'board.calendar_linked', level: 'success', actor: 'operator', season_id: season.id,
          subject_type: 'fin_event', subject_key: fin_event_id,
          data: { 'calendar_id' => @calendar.id, 'changes' => changes.keys, 'sql_filename' => File.basename(sql_path.to_s) },
          link_path: Rails.application.routes.url_helpers.season_board_path
        )
      end
    end

    # Registers 'NNNN-calendar_link-<calendar_id>-<fin_event_id>.sql' in the Outbox; returns the Ops::SqlScript.
    def write_sql_file(sql)
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
      @script = Outbox::Writer.write!(
        kind: 'calendar_link', name: "calendar_link-#{@calendar.id}-#{fin_event_id}", sql: "#{lines.join("\r\n")}\r\n",
        folder: season.id.to_s, season_id: season.id, data_root:,
        origin: { 'producer' => 'season_board.calendar_link', 'calendar_id' => @calendar.id, 'fin_event_id' => fin_event_id,
                  'meeting_id' => @calendar.meeting_id }.compact
      )
    end
  end
end
