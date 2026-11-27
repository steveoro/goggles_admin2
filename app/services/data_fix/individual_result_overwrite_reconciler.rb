# frozen_string_literal: true

require 'set'

module DataFix
  # Finds individual results that are present for a represented swimmer/team in
  # the database but absent from the imported meeting result set.
  #
  # Also classifies each deletion candidate. A unique imported row for the same
  # swimmer/team/session/event/gender in a different program is a category
  # correction: when no correct-program MIR exists it can be reassigned in
  # place; when one exists it is a true duplicate merge. Exact total timing only
  # decides whether old split data can be preserved.
  class IndividualResultOverwriteReconciler
    SNAPSHOT_VERSION = 3
    SUPPORTED_SNAPSHOT_VERSIONS = [2, 3].freeze
    EMPTY_SET = Set.new.freeze

    attr_reader :meeting_id, :import_rows

    def initialize(meeting_id:, import_rows:)
      @meeting_id = meeting_id.to_i
      @import_rows = import_rows
    end

    def discover
      return [] unless meeting_id.positive?

      candidates = represented_pairs.each_with_object([]) do |(swimmer_id, team_id), result|
        imported_program_ids = imported_program_ids_by_pair[[swimmer_id, team_id]] || EMPTY_SET
        (existing_results_by_pair[[swimmer_id, team_id]] || []).each do |mir|
          next if imported_program_ids.include?(mir.meeting_program_id.to_i)

          result << candidate_attributes(mir)
        end
      end
      candidates.sort_by { |candidate| sort_key(candidate) }
    end

    def self.snapshot(candidates)
      {
        'version' => SNAPSHOT_VERSION,
        'candidates' => Array(candidates).map do |candidate|
          stringify_keys(candidate).tap do |entry|
            entry['selected'] = default_selected?(entry) unless entry.key?('selected')
            entry['merge'] = default_merge?(entry) unless entry.key?('merge')
          end
        end
      }
    end

    def self.update_selection(snapshot:, candidate_id:, selected:)
      validate_snapshot_shape!(snapshot)
      candidates = Array(snapshot['candidates']).map(&:dup)
      candidate = candidates.find { |entry| entry['id'].to_i == candidate_id.to_i }
      raise ArgumentError, "Unknown individual-result overwrite candidate #{candidate_id}" unless candidate

      candidate['selected'] = ActiveModel::Type::Boolean.new.cast(selected)
      candidate['merge'] = candidate['selected'] == true ? default_merge?(candidate) : false
      snapshot.merge('version' => SNAPSHOT_VERSION, 'candidates' => candidates)
    end

    def self.update_merge_selection(snapshot:, candidate_id:, merge:)
      validate_snapshot_shape!(snapshot)
      candidates = Array(snapshot['candidates']).map(&:dup)
      candidate = candidates.find { |entry| entry['id'].to_i == candidate_id.to_i }
      raise ArgumentError, "Unknown individual-result overwrite candidate #{candidate_id}" unless candidate

      merge_flag = ActiveModel::Type::Boolean.new.cast(merge)
      if merge_flag && (candidate['merge_target_import_key'].blank? || candidate['merge_target_state'] == 'target_unbound')
        raise ArgumentError, "Cannot enable merge for candidate #{candidate_id}: no correct-program merge target"
      end

      candidate['merge'] = merge_flag
      snapshot.merge('version' => SNAPSHOT_VERSION, 'candidates' => candidates)
    end

    def self.validate_snapshot!(meeting_id:, import_rows:, snapshot:)
      validate_snapshot_shape!(snapshot)

      reconciler = new(meeting_id:, import_rows:)
      expected = reconciler.discover.index_by { |candidate| candidate['id'].to_i }
      stored = Array(snapshot['candidates'])

      validate_stored_candidates!(expected, stored)
      stored.filter_map { |candidate| candidate['id'].to_i if candidate['selected'] == true }.uniq
    end

    # Returns a commit plan splitting selected candidates into plain deletions,
    # true correct-target merges, and in-place reassignments. Pairing data is
    # recomputed from the current import rows/DB so stale or drifted metadata
    # fails closed instead of silently changing semantics.
    def self.commit_plan_for(meeting_id:, import_rows:, snapshot:)
      validate_snapshot_shape!(snapshot)

      reconciler = new(meeting_id:, import_rows:)
      expected = reconciler.discover.index_by { |candidate| candidate['id'].to_i }
      stored = Array(snapshot['candidates'])

      validate_stored_candidates!(expected, stored)

      stored.each_with_object({ 'delete_ids' => [], 'merge_targets' => {}, 'reassign_targets' => {} }) do |candidate, plan|
        next unless candidate['selected'] == true

        id = candidate['id'].to_i
        current = expected[id]
        validate_target_snapshot!(candidate, current)

        case current['target_state']
        when 'target_unbound'
          plan['reassign_targets'][id] = merge_target_snapshot(current)
        when 'target_bound'
          if candidate['merge'] == true
            plan['merge_targets'][id] = merge_target_snapshot(current)
          else
            plan['delete_ids'] << id
          end
        when 'target_conflict'
          raise ArgumentError, "Invalid individual-result overwrite target for MIR #{id}: #{current['target_state']}"
        else
          # No unique replacement: this is the explicit destructive absent-row case.
          plan['delete_ids'] << id
        end
      end
    end

    def self.validate_stored_candidates!(expected, stored)
      stored.each do |candidate|
        id = candidate['id'].to_i
        current = expected[id]
        next if current && same_scope?(current, candidate)

        raise ArgumentError, "Stale individual-result overwrite snapshot for MIR #{id}"
      end
    end

    def self.validate_target_snapshot!(stored, current)
      return if stored['merge_target_import_key'].blank?
      return if current['merge_target_import_key'] == stored['merge_target_import_key'] &&
                current['merge_target_program_key'] == stored['merge_target_program_key'] &&
                current['merge_target_timing'].to_s == stored['merge_target_timing'].to_s

      raise ArgumentError, "Stale individual-result overwrite target for MIR #{stored['id']}"
    end

    def self.merge_target_snapshot(current)
      {
        'import_key' => current['merge_target_import_key'],
        'program_key' => current['merge_target_program_key'],
        'meeting_program_id' => current['merge_target_meeting_program_id'],
        'swimmer_id' => current['merge_target_swimmer_id'],
        'team_id' => current['merge_target_team_id'],
        'timing' => current['merge_target_timing'],
        'timing_exact' => current['merge_target_timing_exact'] == true,
        'reconciliation_kind' => current['reconciliation_kind'],
        'target_state' => current['target_state'],
        'lap_count' => current['merge_target_lap_count']
      }
    end

    def self.default_selected?(candidate)
      return false if disqualified?(candidate) || candidate['disqualification_notes'].to_s.strip.present?

      candidate['minutes'].to_i.positive? || candidate['seconds'].to_i.positive? || candidate['hundredths'].to_i.positive?
    end

    def self.disqualified?(candidate)
      value = candidate['disqualified']
      !!ActiveModel::Type::Boolean.new.cast(value)
    end

    def self.default_merge?(candidate)
      candidate['selected'] == true && candidate['merge_target_import_key'].present? && candidate['merge_target_state'] == 'target_bound'
    end

    def self.validate_snapshot_shape!(snapshot)
      return if snapshot.is_a?(Hash) && SUPPORTED_SNAPSHOT_VERSIONS.include?(snapshot['version'].to_i) && snapshot['candidates'].is_a?(Array)

      raise ArgumentError, 'Invalid individual-result overwrite snapshot'
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    def self.same_scope?(left, right)
      %w[id meeting_program_id swimmer_id team_id minutes seconds hundredths].all? do |key|
        left[key].to_i == right[key].to_i
      end
    end

    private

    def represented_pairs
      import_rows.filter_map do |row|
        swimmer_id = row.swimmer_id.to_i
        team_id = row.team_id.to_i
        next unless swimmer_id.positive? && team_id.positive?

        [swimmer_id, team_id]
      end.uniq
    end

    def imported_program_ids_by_pair
      @imported_program_ids_by_pair ||= import_rows.each_with_object({}) do |row, index|
        next unless row.meeting_program_id.to_i.positive?

        key = [row.swimmer_id.to_i, row.team_id.to_i]
        (index[key] ||= Set.new) << row.meeting_program_id.to_i
      end
    end

    def existing_results_by_pair
      @existing_results_by_pair ||= GogglesDb::MeetingIndividualResult
                                    .joins(meeting_program: { meeting_event: :meeting_session })
                                    .where(
                                      meeting_sessions: { meeting_id: meeting_id },
                                      swimmer_id: represented_pairs.map(&:first),
                                      team_id: represented_pairs.map(&:last)
                                    )
                                    .includes(:swimmer, :team, :laps, meeting_program: [:category_type, :gender_type,
                                                                                        { meeting_event: %i[event_type meeting_session] }])
                                    .group_by { |mir| [mir.swimmer_id.to_i, mir.team_id.to_i] }
    end

    # Import rows indexed by the stable same-participation identity. Timing is
    # deliberately not part of the key: an authoritative timing correction is
    # still the same logical meeting entry.
    def import_rows_by_identity
      @import_rows_by_identity ||= import_rows.group_by do |row|
        identity_key_for(row)
      end
    end

    def identity_key_for(row)
      parts = program_key_parts(row.meeting_program_key)
      [row.swimmer_id.to_i, row.team_id.to_i, parts[0].to_i, parts[1].to_s, parts[3].to_s]
    end

    def program_key_parts(key)
      key.to_s.split('-', 4)
    end

    def phase_file_path
      @phase_file_path ||= import_rows.filter_map { |row| row.respond_to?(:phase_file_path) ? row.phase_file_path : nil }.first
    end

    def lap_count_for(import_key)
      (@lap_count_by_import_key ||= {})[import_key] ||=
        GogglesDb::DataImportLap.where(parent_import_key: import_key, phase_file_path: phase_file_path).count
    end

    def candidate_attributes(mir)
      candidate = mir_attributes(mir).merge(program_attributes(mir))
      targets = find_reconciliation_targets(candidate)

      if targets.size == 1
        candidate.merge!(merge_target_fields(targets.first, candidate))
      else
        candidate.merge!(no_merge_target_fields(targets.size > 1))
      end

      candidate['merge'] = self.class.default_merge?(candidate)
      candidate
    end

    def merge_target_fields(target, candidate)
      correct_results = correct_results_for(target, candidate)
      target_state = target_state_for(target, correct_results)
      timing_exact = target.to_timing.to_hundredths == candidate_timing(candidate)

      {
        'merge_available' => true,
        'merge_ambiguous' => false,
        'merge_target_import_key' => target.import_key,
        'merge_target_program_key' => target.meeting_program_key,
        'merge_target_meeting_program_id' => target.meeting_program_id,
        'merge_target_swimmer_id' => target.swimmer_id,
        'merge_target_team_id' => target.team_id,
        'merge_target_timing' => target.to_timing.to_s,
        'merge_target_timing_exact' => timing_exact,
        'merge_target_lap_count' => lap_count_for(target.import_key),
        'merge_target_state' => target_state,
        'target_state' => target_state,
        'target_mir_id' => correct_results.first&.id,
        'reconciliation_kind' => timing_exact ? 'category_correction_exact' : 'category_correction_timing_change'
      }
    end

    def no_merge_target_fields(ambiguous)
      {
        'merge_available' => false,
        'merge_ambiguous' => ambiguous,
        'merge_target_import_key' => nil,
        'merge_target_program_key' => nil,
        'merge_target_meeting_program_id' => nil,
        'merge_target_swimmer_id' => nil,
        'merge_target_team_id' => nil,
        'merge_target_timing' => nil,
        'merge_target_timing_exact' => false,
        'merge_target_lap_count' => 0,
        'merge_target_state' => ambiguous ? 'target_conflict' : 'target_missing',
        'target_state' => ambiguous ? 'target_conflict' : 'target_missing',
        'target_mir_id' => nil,
        'reconciliation_kind' => ambiguous ? 'ambiguous' : 'absent'
      }
    end

    def target_state_for(target, correct_results)
      return 'target_conflict' if correct_results.size > 1
      return 'target_bound' if correct_results.size == 1

      target.meeting_individual_result_id.to_i.positive? ? 'target_conflict' : 'target_unbound'
    end

    def correct_results_for(target, candidate)
      pair = [candidate['swimmer_id'].to_i, candidate['team_id'].to_i]
      (existing_results_by_pair[pair] || []).select do |mir|
        mir.id.to_i != candidate['id'].to_i && program_key_for_mir(mir) == target.meeting_program_key.to_s
      end
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
        'disqualification_notes' => mir.disqualification_notes,
        'timing' => mir.to_timing.to_s,
        'lap_count' => mir.laps.size,
        'swimmer_name' => mir.swimmer&.complete_name,
        'swimmer_year_of_birth' => mir.swimmer&.year_of_birth,
        'team_name' => mir.team&.editable_name || mir.team&.name,
        'selected' => self.class.default_selected?(
          'minutes' => mir.minutes,
          'seconds' => mir.seconds,
          'hundredths' => mir.hundredths,
          'disqualified' => mir.disqualified,
          'disqualification_notes' => mir.disqualification_notes
        ),
        'reason' => 'Not present in imported source'
      }
    end

    def program_attributes(mir)
      program = mir.meeting_program
      event = program.meeting_event
      session_order = event.meeting_session&.session_order
      event_code = event.event_type&.code
      category_code = program.category_type&.code
      gender_code = program.gender_type&.code

      {
        'session_order' => session_order,
        'event_code' => event_code,
        'category_code' => category_code,
        'gender_code' => gender_code,
        'meeting_program_key' => [session_order, event_code, category_code, gender_code].compact.join('-'),
        'meeting_program_id' => mir.meeting_program_id
      }
    end

    def program_key_for_mir(mir)
      program = mir.meeting_program
      event = program.meeting_event
      [event.meeting_session&.session_order, event.event_type&.code, program.category_type&.code, program.gender_type&.code].compact.join('-')
    end

    def find_reconciliation_targets(candidate)
      parts = program_key_parts(candidate['meeting_program_key'])
      identity = [candidate['swimmer_id'].to_i, candidate['team_id'].to_i, parts[0].to_i, parts[1].to_s, parts[3].to_s]
      matches = (import_rows_by_identity[identity] || []).select do |row|
        row.meeting_program_key.to_s != candidate['meeting_program_key'].to_s &&
          row.meeting_individual_result_id.to_i != candidate['id'].to_i
      end
      matches.sort_by { |row| row.import_key.to_s }
    end

    def candidate_timing(candidate)
      Timing.new(
        minutes: candidate['minutes'].to_i,
        seconds: candidate['seconds'].to_i,
        hundredths: candidate['hundredths'].to_i
      ).to_hundredths
    end

    def sort_key(candidate)
      [candidate['session_order'].to_i, candidate['event_code'].to_s, candidate['category_code'].to_s,
       candidate['gender_code'].to_s, candidate['rank'].to_i, candidate['id'].to_i]
    end
  end
end
