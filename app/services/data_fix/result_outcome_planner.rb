# frozen_string_literal: true

module DataFix
  # Read-only Phase 5 outcome model. It explains what commit will do with each
  # staged individual result instead of equating "unbound staging row" with
  # "new MIR". Relay rows intentionally keep their existing simpler counting.
  class ResultOutcomePlanner
    COMPARED_COLUMNS = %w[rank minutes seconds hundredths disqualified standard_points meeting_points goggle_cup_points].freeze

    attr_reader :source_path, :meeting_id, :season_id, :row_outcomes, :candidate_outcomes, :counts, :warnings

    def initialize(source_path:, meeting_id:, season_id:, overwrite_enabled:, overwrite_candidates: [], badge_rows: [])
      @source_path = source_path
      @meeting_id = meeting_id.to_i
      @season_id = season_id.to_i
      @overwrite_enabled = overwrite_enabled == true
      @stored_candidates = Array(overwrite_candidates)
      @badge_rows = Array(badge_rows)
      build!
    end

    def outcome_for(import_key)
      row_outcomes[import_key.to_s]
    end

    def to_h
      {
        'counts' => counts,
        'row_outcomes' => row_outcomes,
        'candidate_outcomes' => candidate_outcomes,
        'warnings' => warnings
      }
    end

    private

    def build!
      rows = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).to_a
      discovered = DataFix::IndividualResultOverwriteReconciler.new(meeting_id:, import_rows: rows).discover
      discovered.index_by { |candidate| candidate['id'].to_i }
      stored_by_id = @stored_candidates.index_by { |candidate| candidate['id'].to_i }
      candidates = discovered.map do |current|
        stored = stored_by_id[current['id'].to_i] || {}
        stored_selected = if @overwrite_enabled
                            stored.key?('selected') ? stored['selected'] == true : false
                          else
                            current['selected'] == true
                          end
        current.merge('selected' => stored_selected,
                      'merge' => stored.key?('merge') ? stored['merge'] == true : current['merge'] == true,
                      'missing_from_stored_snapshot' => @overwrite_enabled && stored.empty?)
      end

      target_by_import_key = candidates.index_by { |candidate| candidate['merge_target_import_key'] }.reject { |key, _| key.blank? }
      existing_rows = GogglesDb::MeetingIndividualResult.where(id: rows.filter_map(&:meeting_individual_result_id)).index_by(&:id)
      @row_outcomes = {}
      @candidate_outcomes = {}
      @warnings = []
      @counts = Hash.new(0)
      counts[:total_rows] = rows.size

      rows.each do |row|
        outcome = row_outcome(row, target_by_import_key[row.import_key], existing_rows)
        row_outcomes[row.import_key] = outcome
        counts[outcome['outcome'].to_sym] += 1
      end

      candidates.each do |candidate|
        outcome = candidate_outcome(candidate)
        candidate_outcomes[candidate['id'].to_i] = outcome
        counts[outcome] += 1
      end

      counts[:physical_creates] = counts[:create] + counts[:duplicate_risk] + counts[:reconciliation_available]
      counts[:net_mir_delta] = counts[:physical_creates] - counts[:candidate_delete] - counts[:candidate_merge]
      counts[:badge_category_updates] = badge_category_update_count
      build_warnings(candidates)
    end

    def row_outcome(row, candidate, existing_rows)
      base = {
        'import_key' => row.import_key,
        'meeting_individual_result_id' => row.meeting_individual_result_id,
        'program_key' => row.meeting_program_key
      }
      if candidate && overwrite_enabled? && candidate['selected'] == true
        if candidate['merge_target_state'] == 'target_unbound'
          lap_effect_key = candidate['merge_target_timing_exact'] == true ? 'preserve' : 'replace'
          return base.merge('outcome' => 'reassign', 'source_mir_id' => candidate['id'],
                            'old_program_key' => candidate['meeting_program_key'],
                            'timing_exact' => candidate['merge_target_timing_exact'] == true,
                            'lap_effect' => lap_effect_key,
                            'label' => I18n.t('data_import.data_fix.outcome_label_reassign',
                                              mir_id: candidate['id'],
                                              lap_effect: I18n.t("data_import.data_fix.outcome_lap_effect_#{lap_effect_key}")))
        end
        if candidate['merge'] == true
          return base.merge('outcome' => 'merge_target', 'source_mir_id' => candidate['id'],
                            'old_program_key' => candidate['meeting_program_key'],
                            'label' => I18n.t('data_import.data_fix.outcome_label_merge_target', mir_id: candidate['id']))
        end
        return base.merge('outcome' => 'create', 'source_mir_id' => candidate['id'],
                          'old_program_key' => candidate['meeting_program_key'],
                          'label' => I18n.t('data_import.data_fix.outcome_label_create_replacement', mir_id: candidate['id']))
      end
      if candidate && row.meeting_individual_result_id.nil?
        kind = overwrite_enabled? ? 'duplicate_risk' : 'reconciliation_available'
        return base.merge('outcome' => kind, 'source_mir_id' => candidate['id'],
                          'old_program_key' => candidate['meeting_program_key'],
                          'label' => I18n.t(outcome_label_key_for(kind)))
      end
      return base.merge('outcome' => 'create', 'label' => I18n.t('data_import.data_fix.outcome_label_create')) if row.meeting_individual_result_id.nil?

      existing = existing_rows[row.meeting_individual_result_id.to_i]
      changed = existing && COMPARED_COLUMNS.any? { |column| comparable_value(row, column) != comparable_value(existing, column) }
      base.merge('outcome' => changed ? 'update' : 'no_change',
                 'label' => I18n.t(changed ? 'data_import.data_fix.outcome_label_update' : 'data_import.data_fix.outcome_label_no_change'))
    end

    def outcome_label_key_for(kind)
      kind == 'duplicate_risk' ? 'data_import.data_fix.outcome_label_duplicate_risk' : 'data_import.data_fix.outcome_label_reconciliation_available'
    end

    def candidate_outcome(candidate)
      return :candidate_ignored unless overwrite_enabled? && candidate['selected'] == true
      return :candidate_reassign if candidate['merge_target_state'] == 'target_unbound'
      return :candidate_merge if candidate['merge_target_state'] == 'target_bound' && candidate['merge'] == true

      :candidate_delete
    end

    def comparable_value(row, column)
      value = row.public_send(column)
      value.respond_to?(:to_d) && %w[standard_points meeting_points goggle_cup_points].include?(column) ? value.to_d : value
    end

    def overwrite_enabled?
      @overwrite_enabled == true
    end

    def badge_category_update_count
      season = GogglesDb::Season.find_by(id: season_id)
      return 0 unless season&.season_type_id == GogglesDb::SeasonType::MAS_FIN_ID

      ids = @badge_rows.filter_map { |row| row['badge_id'].to_i if row['badge_id'].to_i.positive? }
      badges = GogglesDb::Badge.where(id: ids).index_by(&:id)
      @badge_rows.count do |row|
        badge = badges[row['badge_id'].to_i]
        badge && row['category_type_id'].to_i.positive? && badge.category_type_id.to_i != row['category_type_id'].to_i
      end
    end

    def build_warnings(candidates)
      candidates.each do |candidate|
        next unless candidate['merge_target_import_key'].present? && candidate['selected'] != true

        warnings << I18n.t('data_import.data_fix.outcome_warning_ignored_correction', mir_id: candidate['id'])
      end
      unless overwrite_enabled? || candidates.none? { |c| c['merge_target_import_key'].present? }
        warnings << I18n.t('data_import.data_fix.outcome_warning_reconciliation_off')
      end
      return unless candidates.any? { |c| c['missing_from_stored_snapshot'] == true }

      warnings << I18n.t('data_import.data_fix.outcome_warning_new_candidates')
    end
  end
end
