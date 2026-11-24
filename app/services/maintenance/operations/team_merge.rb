# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::TeamMerge ('team.merge')
    #
    # Merges a source team into a destination one with the exact call of 'merge:team':
    #   Merge::Team.new(source:, dest:, skip_columns:, keep_as_alias:)#prepare, #sql_log
    # #prepare always prints the checker report (captured in the console). A shared badge couple whose sub-merge failed
    # leaves a '-- WARNING:' line in the script: those lines become plan warnings.
    # Typed confirmation ("MERGE <src> INTO <dest>"). Fixes: teams.possible_duplicates, and the team variant of
    # badges.duplicate.possible (the swimmer's two badges are on different teams).
    #
    class TeamMerge < Maintenance::Operation
      self.key = 'team.merge'
      self.confirmation = :typed
      self.outbox_kind = 'merge'
      self.health_group = 'badges'
      self.fixes = %w[teams.possible_duplicates badges.duplicate.possible].freeze
      self.bumps_db_generation = true

      WARNING_PREFIX = '-- WARNING:'

      param :source_id
      param :dest_id
      param :skip_columns, :flag
      param :keep_as_alias, :flag

      validates :source_id, :dest_id, presence: true
      validate :distinct_ids

      # The Merge::Team of the last plan (read by the rake caller, phase 13).
      attr_reader :merger

      # teams.possible_duplicates: the 'rake' ids; badges.duplicate.possible: the teams of the first two badges
      # (dest = the team of the first badge).
      def self.params_from_finding(finding)
        payload = payload_of(finding)
        return { 'source_id' => payload.dig('rake', 'src'), 'dest_id' => payload.dig('rake', 'dest') } if finding.check_key == 'teams.possible_duplicates'

        team_ids = Array(payload['badges']).filter_map { |badge| badge['team_id'] }.uniq
        { 'source_id' => team_ids.second, 'dest_id' => team_ids.first }
      end

      # For badges.duplicate.possible only when the badges are on two different teams.
      def self.offer_for?(finding)
        return false unless super
        return true if finding.check_key == 'teams.possible_duplicates'

        Array(payload_of(finding)['badges']).filter_map { |badge| badge['team_id'] }.uniq.size >= 2
      end

      def file_base = "merge_teams-#{source_id}-#{dest_id}"
      def season_id = nil
      def subject = ['team', source_id]
      def label = I18n.t('maintenance.operations.team_merge.label', source: source_id, dest: dest_id)
      def typed_token = "MERGE #{source_id} INTO #{dest_id}"

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        source = GogglesDb::Team.find_by(id: source_id)
        dest = GogglesDb::Team.find_by(id: dest_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: source_id)]) unless source
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: dest_id)]) unless dest

        @merger = merger = Merge::Team.new(source:, dest:, skip_columns: flag?(:skip_columns), keep_as_alias: flag?(:keep_as_alias))
        merger.prepare
        blank_plan(subjects: [{ 'type' => 'team', 'id' => source.id }, { 'type' => 'team', 'id' => dest.id }],
                   summary: { 'source' => team_facts(source), 'dest' => team_facts(dest),
                              'flags' => %i[skip_columns keep_as_alias].select { |name| flag?(name) }.map(&:to_s) },
                   warnings: merger.sql_log.select { |line| line.to_s.lstrip.start_with?(WARNING_PREFIX) }
                                   .map { |line| line.to_s.strip.delete_prefix('--').strip },
                   sql_lines: merger.sql_log)
      end

      private

      def distinct_ids
        errors.add(:dest_id, I18n.t('maintenance.errors.same_ids')) if source_id.present? && source_id == dest_id
      end

      def team_facts(team)
        { 'id' => team.id, 'name' => team.name, 'editable_name' => team.editable_name, 'city_id' => team.city_id }
      end
    end
  end
end
