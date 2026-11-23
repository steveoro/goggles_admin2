# frozen_string_literal: true

module Health
  # = Health::MeetingCanceller
  #
  # The only write of the data health report: "Flag cancelled" on a meeting and/or its calendar that never got
  # results (same pattern as SeasonBoard::CalendarLinker). Started only by an operator click
  # (Health::CancellationsController), always after the #preview dry run; never by a job or a callback.
  #
  # - #preview writes nothing: it returns the meeting and calendar facts, the current event / MIR / MRR counts,
  #   the SQL (SqlMaker#log_update of 'cancelled' + 'updated_at') and the SHA256 digest of that SQL;
  # - #call(expected_digest:) refuses when the meeting now has results or when the SQL changed since the preview
  #   (digest mismatch); otherwise it flags the rows on the localhost DB and writes the replayable script inside
  #   ONE transaction (no script without its local change):
  #     crawler/data/results.new/<season>/NNNN-meeting_cancel-<meeting_id>.sql   (a meeting, with or without calendar)
  #     crawler/data/results.new/<season>/NNNN-calendar_cancel-<calendar_id>.sql (a calendar alone)
  #   The script is registered in the SQL Outbox (Outbox::Writer, kind 'cancel_flag', NNNN = the global sequence)
  #   and pushed from the Outbox page (its kind, or SeasonBoard::DiskIndex::BOARD_SQL_REGEXP without the ops DB,
  #   keeps it out of the unmatched sources).
  #
  # The local change touches exactly the columns of the script ('cancelled' and 'updated_at', with update_columns),
  # so the local row and the pushed script never differ.
  #
  # Phase 11 replaces this class with the 'meeting.set_cancelled' operation (writing to results.new/misc/).
  #
  # == Usage
  #   canceller = Health::MeetingCanceller.new(season:, meeting_id: 19412, calendar_id: 881)
  #   preview = canceller.preview        # => Preview (error nil when it can be applied)
  #   result = canceller.call(expected_digest: preview.digest)
  #   result.success?  # => true/false; result.sql_path; result.error
  #
  class MeetingCanceller
    # Dry-run outcome: meeting / calendar (AR rows or nil), counts ({ events:, mirs:, mrrs: }), statements (Array
    # of SQL Strings), sql (joined), digest (SHA256 hex of sql), error (String, nil when the cancel can be applied).
    Preview = Data.define(:meeting, :calendar, :counts, :statements, :sql, :digest, :error) do
      def ok? = error.nil?
      def results? = (counts[:mirs].to_i + counts[:mrrs].to_i).positive?
    end

    # Outcome of #call.
    Result = Struct.new(:success, :sql_path, :error, keyword_init: true) do
      def success? = success
    end

    attr_reader :season, :meeting_id, :calendar_id, :data_root

    # == Params
    # - season: GogglesDb::Season (or its ID); meeting_id and/or calendar_id: the rows to flag (one at least);
    # - data_root: crawler data root (default: 'crawler/data').
    def initialize(season:, meeting_id: nil, calendar_id: nil, data_root: SeasonBoard::Backfill::DEFAULT_DATA_ROOT)
      @season = season.is_a?(GogglesDb::Season) ? season : GogglesDb::Season.unscoped.find_by(id: season)
      @meeting_id = meeting_id.presence&.to_i
      @calendar_id = calendar_id.presence&.to_i
      @data_root = Pathname.new(data_root)
    end

    # The dry run: writes nothing.
    def preview
      error = validation_error
      return Preview.new(meeting: @meeting, calendar: @calendar, counts: {}, statements: [], sql: '', digest: nil, error:) if error

      counts = result_counts
      statements = sql_statements
      sql = statements.join("\r\n")
      error = I18n.t('health.cancellations.errors.has_results') if (counts[:mirs] + counts[:mrrs]).positive?
      error ||= I18n.t('health.cancellations.errors.nothing_to_do') if statements.empty?
      Preview.new(meeting: @meeting, calendar: @calendar, counts:, statements:, sql:, digest: Digest::SHA256.hexdigest(sql), error:)
    end

    # Applies the cancel locally and writes the script (one transaction). Returns a Result.
    def call(expected_digest:)
      current = preview
      return Result.new(success: false, error: current.error) unless current.ok?
      return Result.new(success: false, error: I18n.t('health.cancellations.errors.digest_changed')) if current.digest != expected_digest.to_s

      committed = false
      ActiveRecord::Base.transaction do
        flag_rows!
        # Written inside the transaction: on failure no script exists without its local change.
        write_sql_file(current.sql)
      end
      committed = true
      Result.new(success: true, sql_path: @script.absolute_path)
    rescue StandardError => e
      # (the local change rolled back: a script written meanwhile must not stay pushable)
      Outbox::Writer.discard!(@script) unless committed
      Result.new(success: false, error: e.message)
    end

    # 'meeting_cancel' or 'calendar_cancel' (the script name kind).
    def kind
      meeting_id ? 'meeting_cancel' : 'calendar_cancel'
    end

    private

    def validation_error
      return I18n.t('health.cancellations.errors.no_season') unless season
      return I18n.t('health.cancellations.errors.no_target') if meeting_id.nil? && calendar_id.nil?

      meeting_error || calendar_error
    end

    def meeting_error
      return unless meeting_id

      @meeting = GogglesDb::Meeting.unscoped.find_by(id: meeting_id)
      return I18n.t('health.cancellations.errors.meeting_not_found', id: meeting_id) unless @meeting

      I18n.t('health.cancellations.errors.other_season', id: meeting_id) unless @meeting.season_id == season.id
    end

    def calendar_error
      return unless calendar_id

      @calendar = GogglesDb::Calendar.unscoped.find_by(id: calendar_id)
      return I18n.t('health.cancellations.errors.calendar_not_found', id: calendar_id) unless @calendar
      return I18n.t('health.cancellations.errors.other_season', id: calendar_id) unless @calendar.season_id == season.id

      I18n.t('health.cancellations.errors.other_meeting', id: calendar_id) if @meeting && @calendar.meeting_id != @meeting.id
    end

    # Counts of the meeting (or of the meeting linked to the calendar).
    def result_counts
      target_id = @meeting&.id || @calendar&.meeting_id
      return { events: 0, mirs: 0, mrrs: 0 } unless target_id

      events = GogglesDb::MeetingEvent.unscoped.joins(:meeting_session).where(meeting_sessions: { meeting_id: target_id }).count
      { events:, mirs: results_count(GogglesDb::MeetingIndividualResult, target_id),
        mrrs: results_count(GogglesDb::MeetingRelayResult, target_id) }
    end

    def results_count(klass, meeting_id)
      klass.unscoped.joins(meeting_program: { meeting_event: :meeting_session }).where(meeting_sessions: { meeting_id: }).count
    end

    # The rows still to flag.
    def targets
      [@meeting, @calendar].compact.reject(&:cancelled)
    end

    def sql_statements
      targets.map { |row| SqlMaker.new(row:).log_update('cancelled' => true, 'updated_at' => nil) }
    end

    def flag_rows!
      now = Time.current
      targets.each { |row| row.update_columns(cancelled: true, updated_at: now) } # rubocop:disable Rails/SkipsModelValidations
    end

    # Registers 'NNNN-meeting_cancel-<meeting_id>.sql' / 'NNNN-calendar_cancel-<calendar_id>.sql' in the Outbox
    # (results.new/<season>/); returns the Ops::SqlScript.
    def write_sql_file(sql)
      lines = [
        "-- Data health, flag cancelled: season_id=#{season.id}, meeting_id=#{@meeting&.id || '-'}, calendar_id=#{@calendar&.id || '-'}\r\n",
        'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";',
        'SET AUTOCOMMIT = 0;',
        'START TRANSACTION;',
        "--\r\n",
        sql,
        "\r\n--\r\n",
        'COMMIT;'
      ]
      @script = Outbox::Writer.write!(
        kind: 'cancel_flag', name: "#{kind}-#{meeting_id || calendar_id}", sql: "#{lines.join("\r\n")}\r\n",
        folder: season.id.to_s, season_id: season.id, data_root:,
        origin: { 'producer' => 'health.flag_cancelled', 'meeting_id' => @meeting&.id, 'calendar_id' => @calendar&.id }.compact
      )
    end
  end
end
