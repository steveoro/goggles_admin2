# frozen_string_literal: true

module Import
  module Verification
    # Checks whether a MIR or MRR being imported already exists in the database.
    # Used by the Phase 5 verification UI to detect duplicates before commit.
    #
    # For individual results (MIR):
    #   Looks up by meeting_program_id + swimmer_id.
    #   Returns existing MIR(s) with timing comparison and team_id mismatch flag.
    #
    # For relay results (MRR):
    #   Looks up by meeting_program_id + team_id (+ overlapping swimmer group).
    #   Returns existing MRR(s) with timing comparison.
    #
    class ResultDuplicateChecker
      # Check for duplicate individual results.
      #
      # @param swimmer_id [Integer] resolved swimmer DB ID
      # @param meeting_program_id [Integer] resolved meeting program DB ID
      # @param timing [Hash] { minutes:, seconds:, hundredths: } from the import row
      # @param team_id [Integer, nil] team_id from the import row (for mismatch detection)
      # @param season_id [Integer, nil] season for badge lookup
      # @return [Hash] { duplicates: [...], swimmer_badges: [...] }
      def check_individual(swimmer_id:, meeting_program_id:, timing: {}, team_id: nil, season_id: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        result = { duplicates: [], meeting_results: [], swimmer_badges: [] }
        return result unless swimmer_id.to_i.positive?

        import_timing = Timing.new(
          minutes: timing[:minutes].to_i,
          seconds: timing[:seconds].to_i,
          hundredths: timing[:hundredths].to_i
        )

        # 1) Exact-program duplicates (same swimmer + same program)
        if meeting_program_id.to_i.positive?
          existing_mirs = GogglesDb::MeetingIndividualResult
                          .where(meeting_program_id: meeting_program_id, swimmer_id: swimmer_id)
                          .includes(:team, :badge, meeting_program: [meeting_event: :event_type])

          existing_mirs.each do |mir|
            existing_timing = mir.to_timing
            timing_match = import_timing.to_hundredths == existing_timing.to_hundredths
            team_mismatch = team_id.to_i.positive? && mir.team_id != team_id.to_i

            result[:duplicates] << {
              'id' => mir.id,
              'rank' => mir.rank,
              'timing' => existing_timing.to_s,
              'timing_match' => timing_match,
              'timing_diff_hundredths' => (import_timing.to_hundredths - existing_timing.to_hundredths).abs,
              'team_id' => mir.team_id,
              'team_name' => mir.team&.editable_name || mir.team&.name,
              'team_mismatch' => team_mismatch,
              'badge_id' => mir.badge_id,
              'disqualified' => mir.disqualified?
            }
          end

          # 2) Meeting-wide search: find ALL results for this swimmer in the same meeting
          # (different programs — catches wrong-team or wrong-event assignments)
          meeting_program = GogglesDb::MeetingProgram.find_by(id: meeting_program_id)
          if meeting_program
            meeting_id = meeting_program.meeting_event&.meeting_session&.meeting_id
            if meeting_id
              duplicate_ids = result[:duplicates].pluck('id')
              meeting_mirs = GogglesDb::MeetingIndividualResult
                             .joins(meeting_program: { meeting_event: :meeting_session })
                             .where(swimmer_id: swimmer_id, 'meeting_sessions.meeting_id': meeting_id)
                             .where.not(id: duplicate_ids) # exclude already-found exact duplicates
                             .includes(:team, meeting_program: [{ meeting_event: :event_type }, :category_type])

              meeting_mirs.each do |mir|
                existing_timing = mir.to_timing
                event_label = mir.meeting_program&.meeting_event&.event_type&.label || 'N/A' # rubocop:disable Style/SafeNavigationChainLength
                category_code = mir.meeting_program&.category_type&.code || 'N/A'
                team_mismatch = team_id.to_i.positive? && mir.team_id != team_id.to_i

                result[:meeting_results] << {
                  'id' => mir.id,
                  'rank' => mir.rank,
                  'timing' => existing_timing.to_s,
                  'event' => event_label,
                  'category' => category_code,
                  'meeting_program_id' => mir.meeting_program_id,
                  'team_id' => mir.team_id,
                  'team_name' => mir.team&.editable_name || mir.team&.name,
                  'team_mismatch' => team_mismatch,
                  'badge_id' => mir.badge_id,
                  'disqualified' => mir.disqualified?
                }
              end
            end
          end
        end

        # 3) Load swimmer's badges for the season (to detect multi-team enrollment)
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
