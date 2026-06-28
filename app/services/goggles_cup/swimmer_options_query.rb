# frozen_string_literal: true

module GogglesCup
  # Lists swimmers for the GogglesCup primary-team domain.
  class SwimmerOptionsQuery
    def initialize(team_id:)
      @team_id = team_id
    end

    def call
      rows.map do |row|
        {
          swimmer_id: row[0],
          swimmer_name: row[1],
          swimmer_year_of_birth: row[2]
        }
      end
    end

    def smart_selected_ids_for(secondary_team_id)
      return [] if secondary_team_id.blank?

      GogglesDb::Badge
        .where(team_id: secondary_team_id, swimmer_id: rows.map(&:first))
        .distinct
        .pluck(:swimmer_id)
    end

    private

    def rows
      @rows ||= GogglesDb::BestSwimmerCurrentVsPreviousResult
                .where(team_id: @team_id)
                .distinct
                .order(:swimmer_name)
                .pluck(:swimmer_id, :swimmer_name, :swimmer_year_of_birth)
    end
  end
end
