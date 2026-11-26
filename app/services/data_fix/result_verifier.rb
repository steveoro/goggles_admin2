# frozen_string_literal: true

module DataFix
  #
  # = DataFix::ResultVerifier
  #
  # Matches staged individual results (data_import_meeting_individual_results) with the existing DB rows, as the
  # Step 5 "verify" button always did (Import::Verification::ResultDuplicateChecker): a row with EXACTLY ONE perfect
  # match (same event, category, team and timing) takes that row's ids and values, so the commit updates it
  # instead of creating a duplicate. Never touches a row that is the merge target of an overwrite candidate.
  #
  # - #verify_row(row): one row (the JSON endpoint GET data_fix/verify_result);
  # - #verify_all!: every unmatched staged row of the source (run after each Phase 5 populate and by the
  #   POST "Verify all" endpoint). Idempotent: rows already bound to a result are skipped. An optional progress sink
  #   is ticked along the way (it can take a while on a large meeting: the progress strip stays alive).
  #
  class ResultVerifier
    AUTO_FIX_COLUMNS = %i[meeting_program_id swimmer_id team_id badge_id rank minutes seconds hundredths disqualified
                          standard_points meeting_points goggle_cup_points].freeze
    # Rows checked between two progress ticks of #verify_all!, and its default message.
    PROGRESS_EVERY = 25
    PROGRESS_MESSAGE = 'Verifying the staged results'

    attr_reader :source_path, :season_id

    def initialize(source_path:, season_id: nil, checker: Import::Verification::ResultDuplicateChecker.new)
      @source_path = source_path
      @season_id = season_id
      @checker = checker
    end

    # Returns { 'checked', 'verified', 'partial' => [import keys], 'merge_targets_skipped' }.
    # +progress+: an optional Import::Progress sink (or a callable(message, current, total)), ticked with +message+
    # before the first row, every PROGRESS_EVERY rows and after the last one (never when there is nothing to verify).
    def verify_all!(progress: nil, message: PROGRESS_MESSAGE)
      merge_keys = merge_target_import_keys
      outcome = { 'checked' => 0, 'verified' => 0, 'partial' => [], 'merge_targets_skipped' => 0 }
      scope = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path, meeting_individual_result_id: nil)
                                                          .where.not(meeting_program_id: nil).where.not(swimmer_id: nil)
      total = progress ? scope.count : 0
      progress = nil if total.zero? # (nothing to verify: no tick)
      progress&.call(message, 0, total)
      scope.find_each.with_index(1) do |row, index|
        progress.call(message, index, total) if progress && (index % PROGRESS_EVERY).zero?
        if merge_keys.include?(row.import_key)
          outcome['merge_targets_skipped'] += 1
          next
        end

        outcome['checked'] += 1
        result = verify_row(row, merge_target: false)
        outcome['verified'] += 1 if result[:auto_fixed]
        outcome['partial'] << row.import_key if !result[:auto_fixed] && Array(result[:partial_matches]).any?
      end
      progress&.call(message, total, total)
      outcome['partial'] = outcome['partial'].first(200)
      outcome
    rescue StandardError => e
      Rails.logger.error("[DataFix::ResultVerifier] verify_all failed for #{source_path}: #{e.class}: #{e.message}")
      outcome.merge('error' => e.message.truncate(300))
    end

    # Checks one staged individual row; auto-fixes it on exactly one perfect match (unless +merge_target+).
    # Returns the checker Hash (+ :auto_fixed / :auto_fixed_id).
    def verify_row(row, merge_target: nil, season_id: @season_id)
      result = @checker.check_individual(
        swimmer_id: row.swimmer_id, meeting_program_id: row.meeting_program_id,
        timing: { minutes: row.minutes, seconds: row.seconds, hundredths: row.hundredths },
        team_id: row.team_id, season_id:
      )
      return result if merge_target
      return result unless result[:perfect_matches]&.length == 1

      existing = GogglesDb::MeetingIndividualResult.find_by(id: result[:perfect_matches].first['id'])
      return result unless existing

      row.update!(AUTO_FIX_COLUMNS.index_with { |column| existing.public_send(column) }
                                  .merge(meeting_individual_result_id: existing.id))
      result.merge(auto_fixed: true, auto_fixed_id: existing.id)
    end

    private

    # Import keys that an overwrite candidate merges into (never auto-fixed).
    def merge_target_import_keys
      phase5_path = DataFix::SourceResolver.new.default_phase_path_for(source_path, 5)
      return Set.new unless File.exist?(phase5_path)

      overwrite = JSON.parse(File.read(phase5_path)).dig('_meta', 'individual_result_overwrite')
      return Set.new unless overwrite.is_a?(Hash) && overwrite['enabled'] == true

      Array(overwrite.dig('snapshot', 'candidates')).filter_map do |candidate|
        candidate['merge_target_import_key'] if candidate['merge'] == true
      end.to_set
    rescue StandardError
      Set.new
    end
  end
end
