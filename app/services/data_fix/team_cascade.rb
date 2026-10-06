# frozen_string_literal: true

module DataFix
  # TeamCascade: propagates a Phase 2 team_id change downstream — to the Phase 3
  # badges array first, then to the Phase 5 data_import staging rows (MIR, MRR
  # and MRS), re-resolving badge/affiliation bindings deterministically.
  module TeamCascade
    extend self

    # Updates all badges matching team_key and re-resolves binding IDs deterministically.
    # Returns the number of badges updated.
    def cascade_team_to_phase3(phase3_path, team_key, new_team_id, season_id)
      pfm3 = PhaseFileManager.new(phase3_path)
      data3 = pfm3.data || {}
      badges = Array(data3['badges'])
      count = 0
      normalized_team_id = new_team_id.to_i.positive? ? new_team_id.to_i : nil
      normalized_season_id = season_id.to_i.positive? ? season_id.to_i : nil
      resolved_team_affiliation_id = if normalized_team_id && normalized_season_id
                                       GogglesDb::TeamAffiliation.find_by(team_id: normalized_team_id,
                                                                          season_id: normalized_season_id)&.id
                                     end

      badges.each do |badge|
        next unless badge['team_key'] == team_key

        changed = false
        current_team_id = badge['team_id'].to_i.positive? ? badge['team_id'].to_i : nil
        if current_team_id != normalized_team_id
          badge['team_id'] = normalized_team_id
          changed = true
        end

        resolved_badge_id = nil
        if normalized_team_id && normalized_season_id && badge['swimmer_id'].to_i.positive?
          resolved_badge_id = GogglesDb::Badge.find_by(
            season_id: normalized_season_id,
            swimmer_id: badge['swimmer_id'],
            team_id: normalized_team_id
          )&.id
        end
        current_badge_id = badge['badge_id'].to_i.positive? ? badge['badge_id'].to_i : nil
        if current_badge_id != resolved_badge_id
          badge['badge_id'] = resolved_badge_id
          changed = true
        end

        current_affiliation_id = badge['team_affiliation_id'].to_i.positive? ? badge['team_affiliation_id'].to_i : nil
        if current_affiliation_id != resolved_team_affiliation_id
          badge['team_affiliation_id'] = resolved_team_affiliation_id
          changed = true
        end

        count += 1 if changed
      end

      if count.positive?
        data3['badges'] = badges
        pfm3.write!(data: data3, meta: pfm3.meta || {})
        Rails.logger.info("[DataFix] Cascaded team_id=#{normalized_team_id.inspect} to #{count} Phase 3 badge(s) for team_key='#{team_key}'")
      end
      count
    rescue StandardError => e
      Rails.logger.error("[DataFix] cascade_team_to_phase3 failed: #{e.message}")
      0
    end

    # Cascade a team_id change to Phase 5 DataImport rows (MIR, MRR and MRS).
    # Returns the number of rows updated.
    # rubocop:disable-next Rails/SkipsModelValidations
    def cascade_team_to_data_import_rows(team_key, new_team_id, season_id = nil, phase_file_path: nil,
                                         phase2_affiliations: [], phase3_badges: [])
      normalized_team_id = new_team_id.to_i.positive? ? new_team_id.to_i : nil
      normalized_season_id = season_id.to_i.positive? ? season_id.to_i : nil
      resolved_team_affiliation_id = find_phase2_team_affiliation_id(
        team_key: team_key,
        team_id: normalized_team_id,
        season_id: normalized_season_id,
        phase2_affiliations: phase2_affiliations
      )

      mir_scope = GogglesDb::DataImportMeetingIndividualResult.where(team_key: team_key)
      mrr_scope = GogglesDb::DataImportMeetingRelayResult.where(team_key: team_key)
      if phase_file_path.present?
        mir_scope = mir_scope.where(phase_file_path: phase_file_path)
        mrr_scope = mrr_scope.where(phase_file_path: phase_file_path)
      end
      relay_parent_keys = mrr_scope.pluck(:import_key)
      mrs_scope = if relay_parent_keys.present?
                    GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: relay_parent_keys)
                  else
                    GogglesDb::DataImportMeetingRelaySwimmer.none
                  end

      # Index phase3 badges once instead of scanning the array per DataImport row
      badge_index = BadgeResolver.phase3_badge_index(phase3_badges)
      count = 0

      mir_scope.find_each do |row|
        resolved_badge_id = BadgeResolver.resolve_phase3_badge_id(
          swimmer_key: row.swimmer_key,
          swimmer_id: row.swimmer_id,
          team_key: row.team_key,
          team_id: normalized_team_id,
          season_id: normalized_season_id,
          phase3_badges: phase3_badges,
          badge_index: badge_index
        )

        attrs = {}
        attrs[:team_id] = normalized_team_id if row.team_id != normalized_team_id
        attrs[:badge_id] = resolved_badge_id if row.badge_id != resolved_badge_id
        next if attrs.empty?

        row.update_columns(attrs)
        count += 1
      end

      mrr_scope.find_each do |row|
        attrs = {}
        attrs[:team_id] = normalized_team_id if row.team_id != normalized_team_id
        attrs[:team_affiliation_id] = resolved_team_affiliation_id if row.team_affiliation_id != resolved_team_affiliation_id
        next if attrs.empty?

        row.update_columns(attrs)
        count += 1
      end

      mrs_scope.find_each do |row|
        resolved_badge_id = BadgeResolver.resolve_phase3_badge_id(
          swimmer_key: row.swimmer_key,
          swimmer_id: row.swimmer_id,
          team_key: team_key,
          team_id: normalized_team_id,
          season_id: normalized_season_id,
          phase3_badges: phase3_badges,
          badge_index: badge_index
        )
        next if row.badge_id == resolved_badge_id

        row.update_columns(badge_id: resolved_badge_id)
        count += 1
      end

      Rails.logger.info("[DataFix] Cascaded team_id=#{normalized_team_id.inspect} to #{count} DataImport row(s) for team_key='#{team_key}'") if count.positive?
      count
    rescue StandardError => e
      Rails.logger.error("[DataFix] cascade_team_to_data_import_rows failed: #{e.message}")
      0
    end

    private

    def find_phase2_team_affiliation_id(team_key:, team_id:, season_id:, phase2_affiliations:)
      affiliations = Array(phase2_affiliations)
      return nil if affiliations.empty?

      by_team_key = affiliations.find do |row|
        row['team_key'].to_s == team_key.to_s &&
          (!season_id.to_i.positive? || row['season_id'].to_i == season_id.to_i)
      end

      by_team_id = affiliations.find do |row|
        team_id.to_i.positive? && row['team_id'].to_i == team_id.to_i &&
          (!season_id.to_i.positive? || row['season_id'].to_i == season_id.to_i)
      end

      candidate = by_team_key || by_team_id
      candidate_id = candidate&.dig('team_affiliation_id').to_i
      candidate_id.positive? ? candidate_id : nil
    end
  end
end
