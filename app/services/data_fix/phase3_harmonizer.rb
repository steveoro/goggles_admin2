# frozen_string_literal: true

module DataFix
  # Phase3Harmonizer: cross-phase coherence between Phase 2 teams and Phase 3
  # badges — detects conflicts/missing links, annotates Phase 2 teams with
  # conflict-hint candidates, and flags swimmers holding duplicate badges in
  # the same season under different teams.
  module Phase3Harmonizer
    extend self

    def harmonize_phase2_phase3_team_links(source_path:, season_id:)
      phase2_path = SourceResolver.new.default_phase_path_for(source_path, 2)
      phase3_path = SourceResolver.new.default_phase_path_for(source_path, 3)
      return empty_phase3_consistency_stats unless File.exist?(phase2_path) && File.exist?(phase3_path)

      pfm2 = PhaseFileManager.new(phase2_path)
      data2 = pfm2.data || {}
      pfm3 = PhaseFileManager.new(phase3_path)
      data3 = pfm3.data || {}

      teams = Array(data2['teams'])
      swimmers = Array(data3['swimmers'])
      badges = Array(data3['badges'])
      swimmer_by_key = swimmers.index_by { |s| s['key'] }
      # First-match semantics preserved: ||= keeps the earliest entry per key
      teams_by_key = teams.each_with_object({}) { |team, index| index[team['key']] ||= team }

      stats = empty_phase3_consistency_stats
      phase2_changed = false

      badges.each do |badge|
        team_key = badge['team_key']
        next if team_key.blank?

        phase2_team = teams_by_key[team_key]
        next unless phase2_team

        selected_team_id = phase2_team['team_id'].to_i

        canonical_team_id = badge['team_id'].to_i
        if canonical_team_id <= 0
          swimmer_entry = swimmer_by_key[badge['swimmer_key']]
          canonical_team_id = resolve_team_id_from_swimmer_badges(swimmer_entry, team_key:, season_id:)
        end
        next unless canonical_team_id.to_i.positive?
        next if selected_team_id == canonical_team_id

        if selected_team_id.positive?
          stats[:phase2_conflicts_detected] += 1
        else
          stats[:phase2_missing_links_detected] += 1
        end

        next unless append_phase2_team_conflict_hint!(
          phase2_team: phase2_team,
          candidate_team_id: canonical_team_id,
          team_key: team_key,
          current_team_id: selected_team_id
        )

        stats[:phase2_conflict_hints_added] += 1
        phase2_changed = true
      end

      if phase2_changed
        data2['teams'] = teams
        pfm2.write!(data: data2, meta: pfm2.meta || {})
      end

      stats
    rescue StandardError => e
      Rails.logger.error("[DataFix] harmonize_phase2_phase3_team_links failed: #{e.message}")
      empty_phase3_consistency_stats
    end

    def empty_phase3_consistency_stats
      {
        phase2_conflicts_detected: 0,
        phase2_missing_links_detected: 0,
        phase2_conflict_hints_added: 0
      }
    end

    def phase3_conflict_hint?(team_row)
      Array(team_row&.dig('fuzzy_matches')).any? { |match| match['from_phase3_conflict_hint'] == true }
    end

    def append_phase2_team_conflict_hint!(phase2_team:, candidate_team_id:, team_key:, current_team_id:) # rubocop:disable Naming/PredicateMethod
      return false unless phase2_team.is_a?(Hash) && candidate_team_id.to_i.positive?

      candidate_team = GogglesDb::Team.find_by(id: candidate_team_id)
      return false unless candidate_team

      fuzzy_matches = Array(phase2_team['fuzzy_matches'])
      hint_payload = build_phase2_team_conflict_hint(
        phase2_team: phase2_team,
        candidate_team: candidate_team,
        team_key: team_key,
        current_team_id: current_team_id
      )

      existing = fuzzy_matches.find { |match| match['id'].to_i == candidate_team_id.to_i }
      if existing
        merged = existing.merge(hint_payload)
        return false if merged == existing

        existing.replace(merged)
      else
        fuzzy_matches << hint_payload
      end

      fuzzy_matches.sort_by! { |match| -(match['weight'] || 0.0).to_f }
      phase2_team['fuzzy_matches'] = fuzzy_matches
      true
    end

    def build_phase2_team_conflict_hint(phase2_team:, candidate_team:, team_key:, current_team_id:)
      source_name = phase2_team['editable_name'].presence || phase2_team['name'].presence || team_key
      similarity_weight = compute_team_hint_similarity(source_name, candidate_team.editable_name)
      similarity_percentage = (similarity_weight * 100).round(1)
      color_class = case similarity_percentage
                    when 90..100 then 'success'
                    when 70...90 then 'warning'
                    when 50...70 then 'danger'
                    end

      reason = if current_team_id.to_i.positive?
                 "conflicts with selected team ID #{current_team_id}"
               else
                 'fills missing team link from Phase 3 evidence'
               end

      {
        'id' => candidate_team.id,
        'name' => candidate_team.name,
        'editable_name' => candidate_team.editable_name,
        'name_variations' => candidate_team.name_variations,
        'city_id' => candidate_team.city_id,
        'city_name' => candidate_team.city&.name,
        'weight' => similarity_weight,
        'percentage' => similarity_percentage,
        'color_class' => color_class,
        'display_label' => "(Phase3 hint) #{candidate_team.editable_name} " \
                           "(ID: #{candidate_team.id}, #{candidate_team.city&.name || 'no city'}, match: #{similarity_percentage}%)",
        'from_phase3_conflict_hint' => true,
        'phase3_conflict_reason' => reason
      }
    end

    def compute_team_hint_similarity(source_name, candidate_name)
      normalized_source = normalize_team_label_for_similarity(source_name)
      normalized_candidate = normalize_team_label_for_similarity(candidate_name)
      return 0.0 if normalized_source.blank? || normalized_candidate.blank?

      metric = GogglesDb::DbFinders::BaseStrategy::METRIC
      metric.getDistance(normalized_source.downcase, normalized_candidate.downcase).round(3).clamp(0.0, 1.0)
    rescue StandardError
      0.0
    end

    def normalize_team_label_for_similarity(value)
      base = value.to_s.strip
      return '' if base.empty?

      normalized = I18n.transliterate(base).delete('.').upcase
      %w[SSDRL SSD ASD APD SRL SS AS SD].each do |abbreviation|
        normalized = normalized.gsub(/\b#{abbreviation}\b/, '')
      end
      normalized.squeeze(' ').strip
    end

    def resolve_team_id_from_swimmer_badges(swimmer_entry, team_key:, season_id:)
      return nil unless swimmer_entry.is_a?(Hash)

      swimmer_id = swimmer_entry['swimmer_id'].to_i
      matches = Array(swimmer_entry['fuzzy_matches'])
      selected_match = matches.find { |match| match['id'].to_i == swimmer_id }
      selected_match ||= matches.first
      badges = Array(selected_match&.dig('badges'))
      return nil if badges.empty?

      normalized_team_key = normalize_team_label(team_key)
      candidate = badges.find do |badge|
        badge['season_id'].to_i == season_id.to_i &&
          normalize_team_label(badge['team_name']) == normalized_team_key
      end
      candidate ||= badges.find { |badge| badge['season_id'].to_i == season_id.to_i }
      candidate ||= badges.find { |badge| normalize_team_label(badge['team_name']) == normalized_team_key }
      candidate ||= badges.first
      candidate&.dig('team_id').to_i
    end

    def normalize_team_label(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end

    def annotate_swimmer_badge_duplicates!(swimmers)
      summary = { swimmers_with_duplicates: 0, duplicate_seasons: [] }

      swimmers.each do |swimmer|
        swimmer['has_badge_duplicates'] = false
        swimmer['badge_duplicate_summary'] = nil
        swimmer['badge_duplicates'] = []

        swimmer_id = swimmer['swimmer_id'].to_i
        matches = Array(swimmer['fuzzy_matches'])
        selected_match = matches.find { |match| match['id'].to_i == swimmer_id }
        selected_match ||= matches.first
        badges = Array(selected_match&.dig('badges'))
        next if badges.empty?

        duplicates = badges.group_by { |badge| badge['season_id'].to_i }
                           .transform_values { |group| group.filter_map { |badge| badge['team_id'].to_i if badge['team_id'].to_i.positive? }.uniq }
                           .select { |_season_id, team_ids| team_ids.size > 1 }
        next if duplicates.empty?

        swimmer['has_badge_duplicates'] = true
        swimmer['badge_duplicates'] = duplicates.map do |dup_season_id, team_ids|
          { 'season_id' => dup_season_id, 'team_ids' => team_ids }
        end
        swimmer['badge_duplicate_summary'] = swimmer['badge_duplicates'].map do |row|
          team_list = row['team_ids'].join(', ')
          "#{row['team_ids'].size} duplicate badges found in season #{row['season_id']}: team #{team_list}"
        end.join(' · ')

        summary[:swimmers_with_duplicates] += 1
        summary[:duplicate_seasons].concat(duplicates.keys)
      end

      summary[:duplicate_seasons] = summary[:duplicate_seasons].uniq.sort
      summary
    end
  end
end
