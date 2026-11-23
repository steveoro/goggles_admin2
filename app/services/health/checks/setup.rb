# frozen_string_literal: true

module Health
  module Checks
    #
    # = Health::Checks::Setup
    #
    # The 'setup' group (2 counts): season.setup, a season without CategoryTypes or without StandardTimings
    # (error for a current or upcoming season, info for a closed one). The how-to points to
    # docs/HOWTO_prepare_new_season_at_championship_start.md.
    #
    class Setup < Base
      def call
        categories = GogglesDb::CategoryType.unscoped.where(season_id:).count
        timings = GogglesDb::StandardTiming.unscoped.where(season_id:).count
        return [] if categories.positive? && timings.positive?

        [finding('season.setup', severity: closed? ? 'info' : 'error', subject_type: 'season', subject_id: season_id,
                                 identity: "season:#{season_id}",
                                 title_args: { id: season_id, categories:, timings: },
                                 payload: { 'season_id' => season_id, 'description' => season.description,
                                            'category_types' => categories, 'standard_timings' => timings,
                                            'doc' => Health::Registry.fetch('season.setup').doc })]
      end
    end
  end
end
