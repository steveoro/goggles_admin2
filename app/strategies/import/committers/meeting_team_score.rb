# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingTeamScore
    #
    # Commits one overall team-ranking row (GogglesDb::MeetingTeamScore) taken from the
    # Phase 2 'team_scores' list (see Import::TeamScoreExtractor).
    #
    # Attribute mapping (same as the legacy solver):
    # - sum_individual_points / meeting_points          => ind_score
    # - sum_relay_points / meeting_relay_points         => overall_score - ind_score
    # - sum_team_points / meeting_team_points           => overall_score
    # - season_points / season_relay_points / season_team_points => 0.0 (no data)
    #
    # An existing row is looked up by (meeting_id, team_id): when found it's updated
    # with the changed columns only, otherwise a new row is inserted.
    #
    class MeetingTeamScore
      include LegacyPersistence

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      # Commits +score_hash+ ({ 'team_key', 'rank', 'ind_score', 'overall_score' }) for the
      # given meeting, season, team & affiliation. Returns the committed row ID or raises an error.
      def commit(score_hash, meeting_id:, season_id:, team_id:, team_affiliation_id:)
        attributes = build_attributes(score_hash, meeting_id:, season_id:, team_id:, team_affiliation_id:)
        team_key = score_hash['team_key']
        existing = GogglesDb::MeetingTeamScore.where(meeting_id:, team_id:).first

        if existing
          changes = changes_for_update(existing, attributes)
          if changes.any?
            existing.assign_attributes(changes)
            existing.save!
            sql_log << SqlMaker.new(row: existing).log_update(changes)
            stats[:team_scores_updated] += 1
            logger.log_success(entity_type: 'MeetingTeamScore', entity_id: existing.id, action: 'updated', entity_key: team_key)
            Rails.logger.info("[MeetingTeamScore] Updated ID=#{existing.id} (rank #{attributes['rank']}, team_id=#{team_id})")
          end
          return existing.id
        end

        model = GogglesDb::MeetingTeamScore.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:team_scores_created] += 1
        logger.log_success(entity_type: 'MeetingTeamScore', entity_id: model.id, action: 'created', entity_key: team_key)
        Rails.logger.info("[MeetingTeamScore] Created ID=#{model.id} (rank #{attributes['rank']}, team_id=#{team_id})")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        error_details = e.record ? GogglesDb::ValidationErrorTools.recursive_error_for(e.record) : e.message
        stats[:errors] << "MeetingTeamScore error (#{team_key}): #{error_details}"
        logger.log_validation_error(entity_type: 'MeetingTeamScore', entity_key: team_key,
                                    entity_id: e.record&.id, model_row: e.record, error: e)
        Rails.logger.error("[MeetingTeamScore] ERROR: #{error_details}")
        raise
      end

      private

      def build_attributes(score_hash, meeting_id:, season_id:, team_id:, team_affiliation_id:)
        ind_score = score_hash['ind_score'].to_f
        overall_score = score_hash['overall_score'].to_f
        {
          'meeting_id' => meeting_id,
          'season_id' => season_id,
          'team_id' => team_id,
          'team_affiliation_id' => team_affiliation_id,
          'rank' => score_hash['rank'].to_i,
          'sum_individual_points' => ind_score,
          'sum_relay_points' => overall_score - ind_score,
          'sum_team_points' => overall_score,
          'meeting_points' => ind_score,
          'meeting_relay_points' => overall_score - ind_score,
          'meeting_team_points' => overall_score,
          'season_points' => 0.0,
          'season_relay_points' => 0.0,
          'season_team_points' => 0.0
        }
      end
    end
  end
end
