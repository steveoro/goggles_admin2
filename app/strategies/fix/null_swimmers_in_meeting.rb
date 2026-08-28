# frozen_string_literal: true

module Fix
  # = Fix::NullSwimmersInMeeting
  #
  #   - version:  7-0.8.41
  #   - author:   Steve A.
  #   - build:    20260828
  #
  # Scans a single Meeting for result rows (MIRs and MRSs) that have a null
  # +swimmer_id+ and a valid badge, and generates the SQL needed to restore the
  # correct swimmer from the badge. The fix is cascaded to child Lap and
  # RelayLap rows where applicable.
  #
  # == Usage:
  #   fixer = Fix::NullSwimmersInMeeting.new(meeting: my_meeting)
  #   fixer.display_report  # preview what will be changed
  #   fixer.prepare         # generate SQL statements
  #
  class NullSwimmersInMeeting # rubocop:disable Metrics/ClassLength
    attr_reader :meeting, :sql_log, :report

    MAX_UNFIXABLE_DETAILS = 20

    # == Params:
    # - <tt>:meeting</tt> => Meeting instance to scan, *required*
    #
    def initialize(meeting: nil)
      raise(ArgumentError, 'meeting must be a Meeting') unless meeting.is_a?(GogglesDb::Meeting)

      @meeting = meeting
      @sql_log = []
      @report = {}
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans the meeting and returns a report hash with fixable/unfixable counts.
    def scan
      return @report if @report.present?

      @report = {
        mirs: scan_mirs,
        mrss: scan_mrss,
        laps: scan_laps,
        relay_laps: scan_relay_laps
      }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Outputs the scan report for this meeting to stdout.
    # rubocop:disable-next Rails/Output, Metrics/AbcSize
    def display_report
      scan

      puts "\r\n--- Meeting #{meeting.id}: #{meeting_label} ---"
      puts "  MIRs: #{@report[:mirs][:fixable]} fixable, #{@report[:mirs][:unfixable]} unfixable"
      puts "        (#{@report[:mirs][:no_badge]} no badge, " \
           "#{@report[:mirs][:missing_badge]} missing badge, " \
           "#{@report[:mirs][:null_badge_swimmer]} badge with null swimmer)"
      puts "        Laps to update: #{@report[:laps][:fixable]}"
      puts "  MRSs: #{@report[:mrss][:fixable]} fixable, #{@report[:mrss][:unfixable]} unfixable"
      puts "        (#{@report[:mrss][:no_badge]} no badge, " \
           "#{@report[:mrss][:missing_badge]} missing badge, " \
           "#{@report[:mrss][:null_badge_swimmer]} badge with null swimmer)"
      puts "        Relay laps to update: #{@report[:relay_laps][:fixable]}"

      display_unfixable_details(:mirs, 'MIR')
      display_unfixable_details(:mrss, 'MRS')
    end
    #-- -----------------------------------------------------------------------
    #++

    # Generates the SQL statements for the fix and returns the +sql_log+ array.
    def prepare
      return @sql_log if @sql_log.present?

      scan
      return @sql_log unless fixable?

      add_meeting_header
      prepare_lap_fixes if @report[:laps][:fixable].positive?
      prepare_mir_fixes if @report[:mirs][:fixable].positive?
      prepare_relay_lap_fixes if @report[:relay_laps][:fixable].positive?
      prepare_mrs_fixes if @report[:mrss][:fixable].positive?

      @sql_log
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns +true+ if there are any rows that can be fixed.
    def fixable?
      scan
      @report.values.any? { |section| section[:fixable].positive? }
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # == Scans ==============================================================

    # Scans MIRs with null swimmer for the meeting.
    def scan_mirs
      base = mir_base_scope.where(swimmer_id: nil)
      build_result(base, 'MIR')
    end

    # Scans MRSs with null swimmer for the meeting.
    def scan_mrss
      base = mrs_base_scope.where(swimmer_id: nil)
      build_result(base, 'MRS')
    end

    # Scans child Laps that will be updated because their parent MIR is fixable.
    def scan_laps
      fixable = lap_base_scope
                .where(laps: { swimmer_id: nil })
                .where(meeting_individual_results: { swimmer_id: nil })
                .where.not(meeting_individual_results: { badge_id: nil })
                .joins(meeting_individual_result: :badge)
                .where.not(badges: { swimmer_id: nil })
                .count

      { fixable: fixable }
    end

    # Scans child RelayLaps that will be updated because their parent MRS is fixable.
    def scan_relay_laps
      fixable = relay_lap_base_scope
                .where(meeting_relay_swimmers: { swimmer_id: nil })
                .where.not(meeting_relay_swimmers: { badge_id: nil })
                .joins(meeting_relay_swimmer: :badge)
                .where.not(badges: { swimmer_id: nil })
                .count

      { fixable: fixable }
    end

    # == Report helpers =====================================================

    # Builds the common report hash for a base relation (MIR or MRS).
    def build_result(base, prefix)
      no_badge = base.where(badge_id: nil).count
      missing_badge = count_missing_badge(base)
      null_badge_swimmer = count_null_badge_swimmer(base)
      fixable = count_fixable(base)

      {
        fixable: fixable,
        no_badge: no_badge,
        missing_badge: missing_badge,
        null_badge_swimmer: null_badge_swimmer,
        unfixable: no_badge + missing_badge + null_badge_swimmer,
        details: unfixable_details(base, prefix)
      }
    end

    # Returns the number of rows that can be fixed (badge exists and has a swimmer).
    def count_fixable(base)
      base.where.not(badge_id: nil)
          .joins(:badge)
          .where.not(badges: { swimmer_id: nil })
          .count
    end

    # Returns the number of rows with a badge_id that does not exist in the DB.
    def count_missing_badge(base)
      base.where.not(badge_id: nil)
          .where.missing(:badge)
          .count
    end

    # Returns the number of rows whose badge exists but has a null swimmer_id.
    def count_null_badge_swimmer(base)
      base.where.not(badge_id: nil)
          .joins(:badge)
          .where(badges: { swimmer_id: nil })
          .count
    end

    # Returns a limited list of human-readable unfixable row descriptions.
    def unfixable_details(base, prefix)
      no_badge = base.where(badge_id: nil)
                     .limit(MAX_UNFIXABLE_DETAILS)
                     .pluck(:id)
                     .map { |id| "#{prefix} #{id}: no badge" }

      missing_badge = base.where.not(badge_id: nil)
                          .where.missing(:badge)
                          .limit(MAX_UNFIXABLE_DETAILS)
                          .pluck(:id, :badge_id)
                          .map { |id, badge_id| "#{prefix} #{id}: missing badge (badge_id=#{badge_id})" }

      null_swimmer = base.where.not(badge_id: nil)
                         .joins(:badge)
                         .where(badges: { swimmer_id: nil })
                         .limit(MAX_UNFIXABLE_DETAILS)
                         .pluck(:id, :badge_id)
                         .map { |id, badge_id| "#{prefix} #{id}: badge #{badge_id} has null swimmer" }

      no_badge + missing_badge + null_swimmer
    end

    # Prints a sample of unfixable rows for a report section.
    # rubocop:disable-next Rails/Output
    def display_unfixable_details(section, label)
      details = @report.dig(section, :details)
      return if details.blank?

      puts "  Unfixable #{label}s (sample of #{details.size}):"
      details.each { |detail| puts "    - #{detail}" }
    end

    # == Base scopes ========================================================

    # Returns the MIR relation scoped to this meeting.
    def mir_base_scope
      GogglesDb::MeetingIndividualResult
        .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
        .where(meetings: { id: meeting.id })
    end

    # Returns the MRS relation scoped to this meeting.
    def mrs_base_scope
      GogglesDb::MeetingRelaySwimmer
        .joins(meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
        .where(meetings: { id: meeting.id })
    end

    # Returns the Lap relation scoped to this meeting.
    def lap_base_scope
      GogglesDb::Lap
        .joins(meeting_individual_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
        .where(meetings: { id: meeting.id })
    end

    # Returns the RelayLap relation scoped to this meeting.
    def relay_lap_base_scope
      GogglesDb::RelayLap
        .joins(meeting_relay_swimmer: { meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } } })
        .where(meetings: { id: meeting.id })
    end

    # == SQL generation =====================================================

    # Adds a header comment for this meeting's SQL section.
    def add_meeting_header
      @sql_log << "-- Meeting #{meeting.id}: #{meeting_label}"
      @sql_log << "-- MIRs: #{@report[:mirs][:fixable]} fixable, #{@report[:mirs][:unfixable]} unfixable"
      @sql_log << "-- MRSs: #{@report[:mrss][:fixable]} fixable, #{@report[:mrss][:unfixable]} unfixable"
      @sql_log << "-- Laps: #{@report[:laps][:fixable]} to fix"
      @sql_log << "-- Relay laps: #{@report[:relay_laps][:fixable]} to fix"
      @sql_log << ''
    end

    # Generates the UPDATE statement for Laps with null swimmer.
    def prepare_lap_fixes
      @sql_log << '-- Fix null swimmers in laps linked to fixable MIRs'
      @sql_log << <<~SQL.squish
        UPDATE laps l
        INNER JOIN meeting_individual_results mir ON mir.id = l.meeting_individual_result_id
        INNER JOIN meeting_programs mp ON mp.id = mir.meeting_program_id
        INNER JOIN meeting_events me ON me.id = mp.meeting_event_id
        INNER JOIN meeting_sessions ms ON ms.id = me.meeting_session_id
        INNER JOIN badges b ON b.id = mir.badge_id
        SET l.swimmer_id = b.swimmer_id, l.updated_at = NOW()
        WHERE ms.meeting_id = #{meeting.id} AND mir.swimmer_id IS NULL AND mir.badge_id IS NOT NULL
          AND b.swimmer_id IS NOT NULL AND l.swimmer_id IS NULL;
      SQL
      @sql_log << ''
    end

    # Generates the UPDATE statement for MIRs with null swimmer.
    def prepare_mir_fixes
      @sql_log << '-- Fix null swimmers in meeting_individual_results'
      @sql_log << <<~SQL.squish
        UPDATE meeting_individual_results mir
        INNER JOIN meeting_programs mp ON mp.id = mir.meeting_program_id
        INNER JOIN meeting_events me ON me.id = mp.meeting_event_id
        INNER JOIN meeting_sessions ms ON ms.id = me.meeting_session_id
        INNER JOIN badges b ON b.id = mir.badge_id
        SET mir.swimmer_id = b.swimmer_id, mir.updated_at = NOW()
        WHERE ms.meeting_id = #{meeting.id} AND mir.swimmer_id IS NULL AND mir.badge_id IS NOT NULL
          AND b.swimmer_id IS NOT NULL;
      SQL
      @sql_log << ''
    end

    # Generates the UPDATE statement for RelayLaps whose parent MRS is fixable.
    def prepare_relay_lap_fixes
      @sql_log << '-- Fix swimmers in relay_laps linked to fixable MRSs'
      @sql_log << <<~SQL.squish
        UPDATE relay_laps rl
        INNER JOIN meeting_relay_swimmers mrs ON mrs.id = rl.meeting_relay_swimmer_id
        INNER JOIN meeting_relay_results mrr ON mrr.id = mrs.meeting_relay_result_id
        INNER JOIN meeting_programs mp ON mp.id = mrr.meeting_program_id
        INNER JOIN meeting_events me ON me.id = mp.meeting_event_id
        INNER JOIN meeting_sessions ms ON ms.id = me.meeting_session_id
        INNER JOIN badges b ON b.id = mrs.badge_id
        SET rl.swimmer_id = b.swimmer_id, rl.updated_at = NOW()
        WHERE ms.meeting_id = #{meeting.id} AND mrs.swimmer_id IS NULL AND mrs.badge_id IS NOT NULL
          AND b.swimmer_id IS NOT NULL;
      SQL
      @sql_log << ''
    end

    # Generates the UPDATE statement for MRSs with null swimmer.
    def prepare_mrs_fixes
      @sql_log << '-- Fix null swimmers in meeting_relay_swimmers'
      @sql_log << <<~SQL.squish
        UPDATE meeting_relay_swimmers mrs
        INNER JOIN meeting_relay_results mrr ON mrr.id = mrs.meeting_relay_result_id
        INNER JOIN meeting_programs mp ON mp.id = mrr.meeting_program_id
        INNER JOIN meeting_events me ON me.id = mp.meeting_event_id
        INNER JOIN meeting_sessions ms ON ms.id = me.meeting_session_id
        INNER JOIN badges b ON b.id = mrs.badge_id
        SET mrs.swimmer_id = b.swimmer_id, mrs.updated_at = NOW()
        WHERE ms.meeting_id = #{meeting.id} AND mrs.swimmer_id IS NULL AND mrs.badge_id IS NOT NULL
          AND b.swimmer_id IS NOT NULL;
      SQL
      @sql_log << ''
    end

    # == Misc ===============================================================

    # Returns a meeting label safe for SQL comments.
    def meeting_label
      label = meeting.respond_to?(:decorate) ? meeting.decorate.display_label : meeting.description
      label.to_s.squish
    end
  end
end
