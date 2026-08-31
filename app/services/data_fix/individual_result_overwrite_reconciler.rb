# frozen_string_literal: true

require 'set'

module DataFix
  # Finds individual results that are present for a represented swimmer/team in
  # the database but absent from the imported meeting result set.
  class IndividualResultOverwriteReconciler
    SNAPSHOT_VERSION = 1

    attr_reader :meeting_id, :import_rows

    def initialize(meeting_id:, import_rows:)
      @meeting_id = meeting_id.to_i
      @import_rows = import_rows
    end

    def discover
      return [] unless meeting_id.positive?

      candidates = represented_pairs.each_with_object([]) do |(swimmer_id, team_id), result|
        imported_program_ids = imported_program_ids_for(swimmer_id, team_id)
        existing_results_for(swimmer_id, team_id).each do |mir|
          next if imported_program_ids.include?(mir.meeting_program_id.to_i)

          result << candidate_attributes(mir)
        end
      end
      candidates.sort_by { |candidate| sort_key(candidate) }
    end

    def self.snapshot(candidates)
      {
        'version' => SNAPSHOT_VERSION,
        'candidates' => Array(candidates).map { |candidate| stringify_keys(candidate) }
      }
    end

    def self.validate_snapshot!(meeting_id:, import_rows:, snapshot:)
      raise ArgumentError, 'Invalid individual-result overwrite snapshot' unless snapshot.is_a?(Hash) && snapshot['version'].to_i == SNAPSHOT_VERSION

      reconciler = new(meeting_id:, import_rows:)
      expected = reconciler.discover.index_by { |candidate| candidate['id'].to_i }
      stored = Array(snapshot['candidates'])

      stored.each do |candidate|
        id = candidate['id'].to_i
        current = expected[id]
        next if current && same_scope?(current, candidate)

        raise ArgumentError, "Stale individual-result overwrite snapshot for MIR #{id}"
      end

      stored.map { |candidate| candidate['id'].to_i }.uniq
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def self.same_scope?(left, right)
      %w[id meeting_program_id swimmer_id team_id].all? do |key|
        left[key].to_i == right[key].to_i
      end
    end

    private

    def represented_pairs
      import_rows.filter_map do |row|
        swimmer_id = row.swimmer_id.to_i
        team_id = row.team_id.to_i
        next unless swimmer_id.positive? && team_id.positive?
        next unless row.meeting_program_id.to_i.positive?

        [swimmer_id, team_id]
      end.uniq
    end

    def imported_program_ids_for(swimmer_id, team_id)
      import_rows.filter_map do |row|
        next unless row.swimmer_id.to_i == swimmer_id && row.team_id.to_i == team_id
        next unless row.meeting_program_id.to_i.positive?

        row.meeting_program_id.to_i
      end.to_set
    end

    def existing_results_for(swimmer_id, team_id)
      GogglesDb::MeetingIndividualResult
        .joins(meeting_program: { meeting_event: :meeting_session })
        .where(meeting_sessions: { meeting_id: meeting_id }, swimmer_id:, team_id:)
        .includes(:swimmer, :team, :laps, meeting_program: [:category_type, :gender_type, { meeting_event: %i[event_type meeting_session] }])
    end

    def candidate_attributes(mir)
      mir_attributes(mir).merge(program_attributes(mir))
    end

    def mir_attributes(mir)
      {
        'id' => mir.id,
        'meeting_program_id' => mir.meeting_program_id,
        'swimmer_id' => mir.swimmer_id,
        'team_id' => mir.team_id,
        'rank' => mir.rank,
        'minutes' => mir.minutes,
        'seconds' => mir.seconds,
        'hundredths' => mir.hundredths,
        'disqualified' => mir.disqualified,
        'timing' => mir.to_timing.to_s,
        'lap_count' => mir.laps.size,
        'swimmer_name' => mir.swimmer&.complete_name,
        'swimmer_year_of_birth' => mir.swimmer&.year_of_birth,
        'team_name' => mir.team&.editable_name || mir.team&.name,
        'reason' => 'Not present in imported source'
      }
    end

    def program_attributes(mir)
      program = mir.meeting_program
      event = program.meeting_event
      {
        'session_order' => event.meeting_session&.session_order,
        'event_code' => event.event_type&.code,
        'category_code' => program.category_type&.code,
        'gender_code' => program.gender_type&.code
      }
    end

    def sort_key(candidate)
      [candidate['session_order'].to_i, candidate['event_code'].to_s, candidate['category_code'].to_s,
       candidate['gender_code'].to_s, candidate['rank'].to_i, candidate['id'].to_i]
    end
  end
end
