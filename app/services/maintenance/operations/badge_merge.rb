# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::BadgeMerge ('badge.merge')
    #
    # Merges a source badge into a destination one, or fixes a badge alone (no destination: relay-only category
    # "auto-fix"), with the exact call of 'merge:badge':
    #   Merge::Badge.new(source:, dest:, keep_dest_columns:, keep_dest_category:, keep_dest_team:, force:, autofix:)
    #   #prepare, #single_transaction_sql_log
    # The flags reach the strategy as true or nil only (Merge::Badge uses .present?: "0" is a validation error here).
    # Checker errors block the plan unless an override flag (force or a keep_*) is set, as the rake task does.
    #
    # From a health finding (one pair per apply: the finding stays open until the re-run shows no pair):
    # - badges.duplicate.sure / .possible: dest = first badge, source = second, autofix (merge.rake 'season_fix');
    # - badges.relay_category: source = the badge, no dest, autofix.
    # Confirmation: one click when source and destination share team and category (or for a lone category fix);
    # typed ("MERGE <src> INTO <dest>") when the teams or categories differ or any keep_* / force flag is set.
    #
    class BadgeMerge < Maintenance::Operation
      self.key = 'badge.merge'
      self.confirmation = :one_click
      self.outbox_kind = 'merge'
      self.health_group = 'badges'
      self.fixes = %w[badges.duplicate.sure badges.duplicate.possible badges.relay_category].freeze
      self.bumps_db_generation = true

      OVERRIDE_FLAGS = %i[keep_dest_columns keep_dest_category keep_dest_team force].freeze
      MAX_FOLLOW_UPS = 10

      param :source_id
      param :dest_id
      param :keep_dest_columns, :flag
      param :keep_dest_category, :flag
      param :keep_dest_team, :flag
      param :force, :flag
      param :autofix, :flag

      validates :source_id, presence: true
      validate :distinct_badges

      # The Merge::Badge of the last plan (read by the rake caller, phase 13).
      attr_reader :merger

      def self.params_from_finding(finding)
        rake = payload_of(finding)['rake'].to_h
        { 'source_id' => rake['src'], 'dest_id' => rake['dest'], 'autofix' => true }.compact
      end

      def file_base
        source = @merger&.source&.id || source_id
        dest = @merger ? @merger.dest&.id : dest_id
        "merge_badges-#{source}-#{dest || 'autofix'}"
      end

      def season_id = source_badge&.season_id

      def subject = ['badge', source_id]

      def label
        return I18n.t('maintenance.operations.badge_merge.label_fix', id: source_id) if dest_id.blank?

        I18n.t('maintenance.operations.badge_merge.label', source: source_id, dest: dest_id)
      end

      def typed_token = dest_id.present? ? "MERGE #{source_id} INTO #{dest_id}" : "FIX #{source_id}"

      def confirmation_for(_plan)
        return :typed if OVERRIDE_FLAGS.any? { |name| flag?(name) }
        return :one_click if source_badge.nil? || dest_badge.nil?

        same = source_badge.team_id == dest_badge.team_id && source_badge.category_type_id == dest_badge.category_type_id
        same ? :one_click : :typed
      end

      # ranks.recompute for the meetings with results of either badge (suggested, never chained).
      def follow_ups(plan)
        Array(plan.summary['meeting_ids']).first(MAX_FOLLOW_UPS).map do |meeting_id|
          { 'operation_key' => 'ranks.recompute', 'params' => { 'meeting_id' => meeting_id } }
        end
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Badge', id: source_id)]) unless source_badge
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Badge', id: dest_id)]) if dest_id.present? && dest_badge.nil?

        meeting_ids = touched_meeting_ids # (before the merge: the source rows still exist)
        @merger = Merge::Badge.new(source: source_badge.decorate, dest: dest_badge&.decorate, keep_dest_columns: flag(:keep_dest_columns),
                                   keep_dest_category: flag(:keep_dest_category), keep_dest_team: flag(:keep_dest_team),
                                   force: flag(:force), autofix: flag(:autofix))
        @merger.prepare
        blocking = OVERRIDE_FLAGS.none? { |name| flag?(name) } ? @merger.errors.map(&:to_s) : []
        blank_plan(subjects: subjects, console: @merger.log.join("\r\n"), summary: summary(meeting_ids),
                   warnings: @merger.warnings.map(&:to_s) + (blocking.empty? ? @merger.errors.map(&:to_s) : []),
                   errors: blocking.empty? ? [] : [I18n.t('maintenance.operations.badge_merge.errors.checker')] + blocking,
                   sql_lines: @merger.single_transaction_sql_log)
      end

      private

      def distinct_badges
        errors.add(:dest_id, I18n.t('maintenance.errors.same_ids')) if dest_id.present? && dest_id == source_id
      end

      def source_badge
        return @source_badge if defined?(@source_badge)

        @source_badge = source_id && GogglesDb::Badge.find_by(id: source_id)
      end

      def dest_badge
        return @dest_badge if defined?(@dest_badge)

        @dest_badge = dest_id.present? ? GogglesDb::Badge.find_by(id: dest_id) : nil
      end

      def subjects
        [source_badge, dest_badge].compact.map { |badge| { 'type' => 'badge', 'id' => badge.id } }
      end

      # Meetings with results (MIR or MRS) of the two badges.
      def touched_meeting_ids
        ids = [source_badge.id, dest_badge&.id].compact
        mirs = GogglesDb::MeetingIndividualResult.unscoped.joins(meeting_program: { meeting_event: :meeting_session })
                                                 .where(badge_id: ids).distinct.pluck('meeting_sessions.meeting_id')
        mrss = GogglesDb::MeetingRelaySwimmer.unscoped.joins(meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } })
                                             .where(badge_id: ids).distinct.pluck('meeting_sessions.meeting_id')
        (mirs + mrss).uniq.sort
      end

      def summary(meeting_ids)
        {
          'source' => badge_facts(@merger.source), 'dest' => @merger.dest && badge_facts(@merger.dest),
          'final_team_id' => safe { @merger.final_team_id }, 'final_category_type_id' => safe { @merger.final_category_type_id },
          'flags' => (OVERRIDE_FLAGS + [:autofix]).select { |name| flag?(name) }.map(&:to_s),
          'meeting_ids' => meeting_ids
        }.compact
      end

      def badge_facts(badge)
        { 'id' => badge.id, 'swimmer_id' => badge.swimmer_id, 'season_id' => badge.season_id, 'team_id' => badge.team_id,
          'team' => badge.team&.name, 'category_type_id' => badge.category_type_id, 'category' => badge.category_type&.code }
      end
    end
  end
end
