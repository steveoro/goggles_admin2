# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::RanksRecompute ('ranks.recompute')
    #
    # Recomputes the MIR / MRR ranks of one meeting (or of a whole season) with Recompute::Ranks (the code of
    # 'recompute:ranks'). Fixes no finding by itself: it is offered as a follow-up button after a 'results.dedupe' or
    # 'badge.merge' apply on the same meeting, never chained. One click.
    #
    class RanksRecompute < Maintenance::Operation
      self.key = 'ranks.recompute'
      self.confirmation = :one_click
      self.outbox_kind = 'recompute'
      self.health_group = nil
      self.fixes = [].freeze

      param :meeting_id
      param :season_id

      validate :one_target

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def file_base = season_param? ? "recompute_ranks-season_#{season_param}" : "recompute_ranks-meeting_#{meeting_id}"

      # (the season param, else the meeting's season)
      def season_id = season_param.presence || meeting&.season_id

      def subject = season_param? ? ['season', season_param] : ['meeting', meeting_id]

      def label
        return I18n.t('maintenance.operations.ranks_recompute.label_season', id: season_param) if season_param?

        I18n.t('maintenance.operations.ranks_recompute.label_meeting', id: meeting_id)
      end

      protected

      def build_plan
        return blank_plan(errors: [not_found_error]) if season.nil? && meeting.nil?

        ranker = Recompute::Ranks.new(season:, meeting:).call
        blank_plan(subjects: [{ 'type' => subject.first, 'id' => subject.second }],
                   summary: { 'season_id' => ranker.season.id, 'meetings' => ranker.updates_by_meeting.size,
                              'updates' => ranker.updates_count, 'updates_by_meeting' => ranker.updates_by_meeting.transform_keys(&:to_s) },
                   sql_lines: ranker.sql_log)
      end

      private

      # The season_id param itself (#season_id falls back to the meeting's season).
      def season_param = attributes['season_id']
      def season_param? = season_param.present?

      def one_target
        errors.add(:base, I18n.t('maintenance.operations.ranks_recompute.errors.no_target')) if meeting_id.blank? && !season_param?
      end

      # The same lookups as the rake task (season first).
      def season
        return @season if defined?(@season)

        @season = season_param? ? GogglesDb::Season.joins(:meetings).includes(:meetings).find_by(id: season_param) : nil
      end

      def meeting
        return @meeting if defined?(@meeting)

        @meeting = meeting_id.present? ? GogglesDb::Meeting.joins(:meeting_programs).includes(:meeting_programs).find_by(id: meeting_id) : nil
      end

      def not_found_error
        return I18n.t('maintenance.errors.not_found', what: 'Season', id: season_param) if season_param?

        I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)
      end
    end
  end
end
