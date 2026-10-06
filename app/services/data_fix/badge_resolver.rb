# frozen_string_literal: true

module DataFix
  # BadgeResolver: resolves badge IDs for data_import rows by looking them up
  # in the Phase 3 badges array (indexed once per cascade run instead of being
  # scanned per row).
  module BadgeResolver
    module_function

    def resolve_phase3_badge_id(swimmer_key:, swimmer_id:, team_key:, team_id:, season_id:, phase3_badges:, badge_index: nil)
      return nil if swimmer_key.blank?

      badge_index ||= phase3_badge_index(phase3_badges)
      matching = phase3_badge_candidates(badge_index, swimmer_key).select do |badge|
        next false if season_id.to_i.positive? && badge['season_id'].to_i.positive? && badge['season_id'].to_i != season_id.to_i

        if team_id.to_i.positive?
          badge['team_id'].to_i == team_id.to_i
        elsif team_key.present?
          badge['team_key'].to_s.casecmp?(team_key.to_s)
        else
          true
        end
      end

      if swimmer_id.to_i.positive?
        matching = matching.select do |badge|
          badge_swimmer_id = badge['swimmer_id'].to_i
          badge_swimmer_id.zero? || badge_swimmer_id == swimmer_id.to_i
        end
      end

      candidate = matching.find { |badge| badge['badge_id'].to_i.positive? }
      candidate&.dig('badge_id').to_i.positive? ? candidate['badge_id'].to_i : nil
    end

    # Index phase3 badges by swimmer key for O(1) lookup in resolve_phase3_badge_id.
    # Each badge is stored under both its raw key and its normalized partial key
    # (exact + partial matching semantics of swimmer_key_match?), as [position, badge]
    # pairs so candidates keep the original array order.
    def phase3_badge_index(phase3_badges)
      Array(phase3_badges).each_with_index.with_object(Hash.new { |h, k| h[k] = [] }) do |(badge, i), index|
        raw_key = badge['swimmer_key'].to_s
        next if raw_key.blank?

        index[raw_key] << [i, badge]
        normalized_key = SwimmerKey.normalize_swimmer_key_for_lookup(raw_key)
        index[normalized_key] << [i, badge] if normalized_key.present? && normalized_key != raw_key
      end
    end

    # Returns phase3 badges matching swimmer_key (exact or normalized key),
    # deduplicated and in original array order.
    def phase3_badge_candidates(badge_index, swimmer_key)
      raw_key = swimmer_key.to_s
      normalized_key = SwimmerKey.normalize_swimmer_key_for_lookup(raw_key)
      tuples = badge_index[raw_key] | (normalized_key.present? ? badge_index[normalized_key] : [])
      tuples.sort_by(&:first).map(&:last)
    end
  end
end
