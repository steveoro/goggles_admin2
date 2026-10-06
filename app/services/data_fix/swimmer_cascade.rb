# frozen_string_literal: true

module DataFix
  # SwimmerCascade: propagates a Phase 3 swimmer update (key and/or swimmer_id)
  # to the Phase 5 data_import staging rows (MIR + MRS), re-resolving badge
  # bindings and rewriting MIR import keys when the canonical key changes.
  module SwimmerCascade
    extend self

    # Cascade a swimmer update from Phase 3 to Phase 5 DataImport rows (MIR + MRS).
    # Returns the number of rows updated.
    # rubocop:disable-next Rails/SkipsModelValidations
    def cascade_swimmer_to_data_import_rows(source_path:, old_swimmer_key:, canonical_swimmer_key:, old_swimmer_id:, new_swimmer_id:, season_id:, phase3_badges:)
      count = 0
      normalized_season_id = season_id.to_i.positive? ? season_id.to_i : nil
      normalized_new_swimmer_id = new_swimmer_id.to_i.positive? ? new_swimmer_id.to_i : nil
      normalized_old_swimmer_id = old_swimmer_id.to_i.positive? ? old_swimmer_id.to_i : nil

      # Index phase3 badges once instead of scanning the array per DataImport row
      badge_index = BadgeResolver.phase3_badge_index(phase3_badges)

      mir_scope = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path)
      mir_scope.find_each do |row|
        next unless SwimmerKey.swimmer_row_matches?(
          row_swimmer_key: row.swimmer_key,
          row_swimmer_id: row.swimmer_id,
          old_swimmer_key: old_swimmer_key,
          canonical_swimmer_key: canonical_swimmer_key,
          old_swimmer_id: normalized_old_swimmer_id,
          new_swimmer_id: normalized_new_swimmer_id
        )

        resolved_badge_id = BadgeResolver.resolve_phase3_badge_id(
          swimmer_key: canonical_swimmer_key.presence || old_swimmer_key,
          swimmer_id: normalized_new_swimmer_id,
          team_key: row.team_key,
          team_id: row.team_id,
          season_id: normalized_season_id,
          phase3_badges: phase3_badges,
          badge_index: badge_index
        )

        attrs = {}
        attrs[:swimmer_id] = normalized_new_swimmer_id if row.swimmer_id != normalized_new_swimmer_id
        attrs[:badge_id] = resolved_badge_id if row.badge_id != resolved_badge_id
        attrs[:swimmer_key] = canonical_swimmer_key if canonical_swimmer_key.present? && row.swimmer_key != canonical_swimmer_key
        old_import_key = row.import_key
        if attrs.any?
          row.update_columns(attrs)
          import_key_changed = rewrite_mir_import_key_if_needed!(row, canonical_swimmer_key)
          if import_key_changed
            GogglesDb::DataImportLap.where(parent_import_key: old_import_key).update_all(
              parent_import_key: row.import_key,
              meeting_individual_result_key: row.import_key
            )
          end
          count += 1
        end
      end

      mrs_scope = GogglesDb::DataImportMeetingRelaySwimmer.where(phase_file_path: source_path)
      # Batch-load parent MRRs once instead of a find_by per relay-swimmer row
      parent_mrrs_by_key = GogglesDb::DataImportMeetingRelayResult
                           .where(import_key: mrs_scope.distinct.pluck(:parent_import_key))
                           .index_by(&:import_key)
      mrs_scope.find_each do |row|
        next unless SwimmerKey.swimmer_row_matches?(
          row_swimmer_key: row.swimmer_key,
          row_swimmer_id: row.swimmer_id,
          old_swimmer_key: old_swimmer_key,
          canonical_swimmer_key: canonical_swimmer_key,
          old_swimmer_id: normalized_old_swimmer_id,
          new_swimmer_id: normalized_new_swimmer_id
        )

        parent_mrr = parent_mrrs_by_key[row.parent_import_key]
        resolved_badge_id = BadgeResolver.resolve_phase3_badge_id(
          swimmer_key: canonical_swimmer_key.presence || old_swimmer_key,
          swimmer_id: normalized_new_swimmer_id,
          team_key: parent_mrr&.team_key,
          team_id: parent_mrr&.team_id,
          season_id: normalized_season_id,
          phase3_badges: phase3_badges,
          badge_index: badge_index
        )

        attrs = {}
        attrs[:swimmer_id] = normalized_new_swimmer_id if row.swimmer_id != normalized_new_swimmer_id
        attrs[:badge_id] = resolved_badge_id if row.badge_id != resolved_badge_id
        attrs[:swimmer_key] = canonical_swimmer_key if canonical_swimmer_key.present? && row.swimmer_key != canonical_swimmer_key
        next if attrs.empty?

        row.update_columns(attrs)
        count += 1
      end

      Rails.logger.info("[DataFix] Cascaded swimmer update to #{count} DataImport row(s) for swimmer_key='#{old_swimmer_key}'") if count.positive?
      count
    rescue StandardError => e
      Rails.logger.error("[DataFix] cascade_swimmer_to_data_import_rows failed: #{e.message}")
      0
    end

    private

    def rewrite_mir_import_key_if_needed!(mir_row, canonical_swimmer_key) # rubocop:disable Naming/PredicateMethod
      return false if canonical_swimmer_key.blank? || mir_row.meeting_program_key.blank?

      current_import_key = mir_row.import_key
      new_import_key = GogglesDb::DataImportMeetingIndividualResult.build_import_key(mir_row.meeting_program_key, canonical_swimmer_key)
      return false if new_import_key == current_import_key

      duplicate = GogglesDb::DataImportMeetingIndividualResult.where(import_key: new_import_key).where.not(id: mir_row.id).exists?
      return false if duplicate

      mir_row.update_columns(import_key: new_import_key) # rubocop:disable Rails/SkipsModelValidations
      true
    end
  end
end
