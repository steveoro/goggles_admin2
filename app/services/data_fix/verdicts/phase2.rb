# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Phase2 (teams)
    #
    # Review: any team per DataFix::ReviewRules.team_needs_review?; more than 25% new teams.
    # Confidently-new teams are listed in +new_entities['teams']+.
    #
    class Phase2 < Base
      PHASE = 2

      protected

      def check # rubocop:disable Metrics/AbcSize
        teams = Array(data['teams'])
        review_rows = teams.select { |team| DataFix::ReviewRules.team_needs_review?(team) }
        review!(:teams_review, count: review_rows.size, details: review_rows.pluck('key'))
        review!(:too_many_new_teams) if DataFix::ReviewRules.too_many_new_teams?(teams)

        new_rows = teams.select { |team| team['team_id'].blank? }
        counts.merge!('teams' => teams.size, 'matched' => teams.size - new_rows.size, 'new' => new_rows.size,
                      'review' => review_rows.size, 'confirmed' => teams.count { |team| DataFix::ReviewRules.confirmed?(team) },
                      'team_scores' => Array(data['team_scores']).size)
        new_entities['teams'] = teams.select { |team| DataFix::ReviewRules.confidently_new_team?(team) }
                                     .map { |team| DataFix::ReviewRules.new_team_entry(team) }
      end
    end
  end
end
