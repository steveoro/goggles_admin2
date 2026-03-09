# frozen_string_literal: true

module Import
  module Verification
    # Checks whether a MIR or MRR being imported already exists in the database.
    # Used by the Phase 5 verification UI to detect duplicates before commit.
    #
    # For individual results (MIR):
    #   Queries all existing results for the same swimmer in the same meeting,
    #   then classifies them into 4 tiers:
    #     - perfect_matches:  same event + same timing + same team (auto-fixable)
    #     - partial_matches:  same event + same team + different timing
    #     - team_mismatches:  same event + different team
    #     - other_events:     different event in the same meeting (informational)
    #
    # For relay results (MRR):
    #   Looks up by meeting_program_id + team_id.
    #   Returns existing MRR(s) with timing comparison.
    #
    class ResultDuplicateChecker
      # Check for duplicate individual results using 4-tier classification.
      #
      # @param swimmer_id [Integer] resolved swimmer DB ID
      # @param meeting_program_id [Integer] resolved meeting program DB ID
      # @param timing [Hash] { minutes:, seconds:, hundredths: } from the import row
      # @param team_id [Integer, nil] team_id from the import row (for mismatch detection)
      # @param season_id [Integer, nil] season for badge lookup
      # @return [Hash] { perfect_matches: [...], partial_matches: [...], team_mismatches: [...],
      #                   other_events: [...], swimmer_badges: [...] }
      def check_individual(swimmer_id:, meeting_program_id:, timing: {}, team_id: nil, season_id: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        result = { perfect_matches: [], partial_matches: [], team_mismatches: [],
                   other_events: [], swimmer_badges: [] }
        return result unless swimmer_id.to_i.positive? && meeting_program_id.to_i.positive?

        import_timing = Timing.new(
          minutes: timing[:minutes].to_i,
          seconds: timing[:seconds].to_i,
          hundredths: timing[:hundredths].to_i
        )

        # Resolve the import row's event_type and category from its meeting_program
        meeting_program = GogglesDb::MeetingProgram
                          .includes(meeting_event: [:event_type, :meeting_session])
                          .find_by(id: meeting_program_id)
        return result unless meeting_program

        import_event_type_id = meeting_program.meeting_event&.event_type_id
        import_category_type_id = meeting_program.category_type_id
        meeting_id = meeting_program.meeting_event&.meeting_session&.meeting_id
        return result unless meeting_id

        # Query ALL existing MIRs for this swimmer in the same meeting
        all_mirs = GogglesDb::MeetingIndividualResult
                   .joins(meeting_program: { meeting_event: :meeting_session })
                   .where(swimmer_id: swimmer_id, 'meeting_sessions.meeting_id': meeting_id)
                   .includes(:team, :badge, meeting_program: [{ meeting_event: :event_type }, :category_type])

        # Classify each existing result into a tier
        all_mirs.each do |mir|
          existing_timing = mir.to_timing
          mir_event_type_id = mir.meeting_program&.meeting_event&.event_type_id
          mir_category_type_id = mir.meeting_program&.category_type_id
          same_event = (mir_event_type_id == import_event_type_id) &&
                       (mir_category_type_id == import_category_type_id)
          same_team = team_id.to_i.positive? && mir.team_id == team_id.to_i
          timing_match = import_timing.to_hundredths == existing_timing.to_hundredths

          row = build_mir_hash(mir, existing_timing, import_timing, team_id)

          if same_event
            if same_team
              if timing_match
                result[:perfect_matches] << row
              else
                result[:partial_matches] << row
              end
            else
              result[:team_mismatches] << row
            end
          else
            row['event'] = mir.meeting_program&.meeting_event&.event_type&.label || 'N/A' # rubocop:disable Style/SafeNavigationChainLength
            row['category'] = mir.meeting_program&.category_type&.code || 'N/A'
            result[:other_events] << row
          end
        end

        # Load swimmer's badges for the season (to detect multi-team enrollment)
        if season_id.to_i.positive?
          badges = GogglesDb::Badge.where(swimmer_id: swimmer_id, season_id: season_id)
                                   .includes(:team)
          badges.each do |badge|
            result[:swimmer_badges] << {
              'badge_id' => badge.id,
              'team_id' => badge.team_id,
              'team_name' => badge.team&.editable_name || badge.team&.name,
              'category_code' => badge.category_type&.code,
              'number' => badge.number
            }
          end
        end

        result
      end

      private

      # Build a standardized hash for an existing MIR.
      def build_mir_hash(mir, existing_timing, import_timing, import_team_id)
        {
          'id' => mir.id,
          'rank' => mir.rank,
          'timing' => existing_timing.to_s,
          'timing_match' => import_timing.to_hundredths == existing_timing.to_hundredths,
          'timing_diff_hundredths' => (import_timing.to_hundredths - existing_timing.to_hundredths).abs,
          'meeting_program_id' => mir.meeting_program_id,
          'team_id' => mir.team_id,
          'team_name' => mir.team&.editable_name || mir.team&.name,
          'team_mismatch' => import_team_id.to_i.positive? && mir.team_id != import_team_id.to_i,
          'badge_id' => mir.badge_id,
          'disqualified' => mir.disqualified?
        }
      end

      public

      # Check for duplicate relay results.
      #
      # @param meeting_program_id [Integer] resolved meeting program DB ID
      # @param team_id [Integer] team_id from the import row
      # @param timing [Hash] { minutes:, seconds:, hundredths: } from the import row
      # @return [Hash] { duplicates: [] }
      def check_relay(meeting_program_id:, team_id:, timing: {}) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        result = { duplicates: [] }
        return result unless meeting_program_id.to_i.positive? && team_id.to_i.positive?

        existing_mrrs = GogglesDb::MeetingRelayResult
                        .where(meeting_program_id: meeting_program_id, team_id: team_id)
                        .includes(:team, :meeting_relay_swimmers)

        existing_mrrs.each do |mrr|
          import_timing = Timing.new(
            minutes: timing[:minutes].to_i,
            seconds: timing[:seconds].to_i,
            hundredths: timing[:hundredths].to_i
          )
          existing_timing = mrr.to_timing
          timing_match = import_timing.to_hundredths == existing_timing.to_hundredths

          swimmers = mrr.meeting_relay_swimmers.order(:relay_order).map do |mrs|
            {
              'relay_order' => mrs.relay_order,
              'swimmer_id' => mrs.swimmer_id,
              'swimmer_name' => mrs.swimmer&.complete_name
            }
          end

          result[:duplicates] << {
            'id' => mrr.id,
            'rank' => mrr.rank,
            'timing' => existing_timing.to_s,
            'timing_match' => timing_match,
            'timing_diff_hundredths' => (import_timing.to_hundredths - existing_timing.to_hundredths).abs,
            'team_id' => mrr.team_id,
            'team_name' => mrr.team&.editable_name || mrr.team&.name,
            'relay_code' => mrr.relay_code,
            'swimmers' => swimmers,
            'disqualified' => mrr.disqualified?
          }
        end

        result
      end
    end
  end
end
