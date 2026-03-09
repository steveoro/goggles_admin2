# frozen_string_literal: true

module Import
  module Verification
    # Cross-validates a Phase 2 team match by checking swimmer badges from Phase 3.
    #
    # For a given team_key, finds up to 3 swimmers linked to that team in Phase 3
    # that have a 100% match (swimmer_id set). For each swimmer, queries their DB badges
    # to extract team_ids, then checks if any of those teams match the Phase 2 candidate.
    #
    # Returns a confidence score (e.g., 3/3 swimmers confirmed = high confidence).
    #
    class TeamSwimmerChecker
      # @param phase3_data [Hash] parsed Phase 3 data payload (the 'data' key contents)
      # @param season_id [Integer] current season ID for badge lookups
      def initialize(phase3_data:, season_id:)
        @phase3_data = phase3_data || {}
        @season_id = season_id
      end

      # Check a team match by cross-referencing swimmer badges.
      #
      # @param team_key [String] the import team key to verify
      # @param candidate_team_id [Integer] the Phase 2 fuzzy-matched team DB ID
      # @return [Hash] {
      #   confirmed: Integer (how many swimmers' badges match the candidate team),
      #   total: Integer (how many reference swimmers were checked),
      #   swimmers: Array of { name:, swimmer_id:, badge_teams: [...], matches_candidate: Boolean },
      #   confidence: String ('high', 'medium', 'low', 'none')
      # }
      def check(team_key:, candidate_team_id:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        result = { confirmed: 0, total: 0, swimmers: [], confidence: 'none' }
        return result unless team_key.present? && candidate_team_id.to_i.positive?

        # Find swimmers linked to this team_key in Phase 3 with a confirmed match (swimmer_id set)
        badges = Array(@phase3_data['badges'])
        swimmers = Array(@phase3_data['swimmers'])

        # Get swimmer keys for this team
        team_badges = badges.select { |b| b['team_key'] == team_key && b['swimmer_id'].to_i.positive? }
        reference_swimmers = team_badges.first(3).filter_map do |badge|
          swimmer_id = badge['swimmer_id'].to_i
          swimmer_entry = swimmers.find { |s| s['swimmer_id'] == swimmer_id }
          next unless swimmer_entry

          {
            swimmer_id: swimmer_id,
            name: swimmer_entry['complete_name'] || "#{swimmer_entry['last_name']} #{swimmer_entry['first_name']}".strip
          }
        end

        return result if reference_swimmers.empty?

        # Batch-load DB badges for all reference swimmers
        swimmer_ids = reference_swimmers.pluck(:swimmer_id)
        db_badges = GogglesDb::Badge.where(swimmer_id: swimmer_ids, season_id: @season_id)
                                    .includes(:team)
                                    .group_by(&:swimmer_id)

        confirmed = 0
        swimmer_details = reference_swimmers.map do |ref|
          swimmer_badges = db_badges[ref[:swimmer_id]] || []
          badge_teams = swimmer_badges.map do |b|
            { 'badge_id' => b.id, 'team_id' => b.team_id, 'team_name' => b.team&.editable_name || b.team&.name }
          end

          matches_candidate = badge_teams.any? { |bt| bt['team_id'] == candidate_team_id }
          confirmed += 1 if matches_candidate

          {
            'name' => ref[:name],
            'swimmer_id' => ref[:swimmer_id],
            'badge_teams' => badge_teams,
            'matches_candidate' => matches_candidate
          }
        end

        total = reference_swimmers.size
        confidence = if total >= 2 && confirmed == total
                       'high'
                     elsif confirmed >= 1
                       'medium'
                     elsif total.positive? && confirmed.zero?
                       'low'
                     else
                       'none'
                     end

        { confirmed: confirmed, total: total, swimmers: swimmer_details, confidence: confidence }
      end
    end
  end
end
