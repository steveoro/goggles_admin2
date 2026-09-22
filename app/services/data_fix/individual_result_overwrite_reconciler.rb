# frozen_string_literal: true

require 'set'

module DataFix
  # Finds individual results that are present for a represented swimmer/team in
  # the database but absent from the imported meeting result set.
  #
  # Also computes merge targets for each deletion candidate: if a single
  # imported result with the same swimmer and the exact same timing exists, the
  # source's laps can be moved to that imported result before the source is
  # deleted.
  class IndividualResultOverwriteReconciler # rubocop:disable Metrics/ClassLength
    SNAPSHOT_VERSION = 2
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
      # When the candidate becomes selected, default merge ON if a single target exists.
      # When unselected, merge is irrelevant, so turn it off.
      candidate['merge'] = candidate['selected'] == true ? default_merge?(candidate) : false
      snapshot.merge('candidates' => candidates)
    end

    def self.update_merge_selection(snapshot:, candidate_id:, merge:)
      validate_snapshot_shape!(snapshot)
      candidates = Array(snapshot['candidates']).map(&:dup)
      candidate = candidates.find { |entry| entry['id'].to_i == candidate_id.to_i }
      raise ArgumentError, "Unknown individual-result overwrite candidate #{candidate_id}" unless candidate

      merge_flag = ActiveModel::Type::Boolean.new.cast(merge)
      raise ArgumentError, "Cannot enable merge for candidate #{candidate_id}: no unique merge target" if merge_flag && candidate['merge_target_import_key'].blank?

      candidate['merge'] = merge_flag
      snapshot.merge('candidates' => candidates)
    end

    def self.validate_snapshot!(meeting_id:, import_rows:, snapshot:)
      validate_snapshot_shape!(snapshot)

      reconciler = new(meeting_id:, import_rows:)
      expected = reconciler.discover.index_by { |candidate| candidate['id'].to_i }
      stored = Array(snapshot['candidates'])

      stored.each do |candidate|
        id = candidate['id'].to_i
        current = expected[id]
        next if current && same_scope?(current, candidate)

        raise ArgumentError, "Stale individual-result overwrite snapshot for MIR #{id}"
      end

      stored.filter_map { |candidate| candidate['id'].to_i if candidate['selected'] == true }.uniq
    end

    # Returns a commit plan splitting selected candidates into plain deletions
    # and merge targets. Recomputes merge targets from the current import rows
    # so the snapshot stays valid even if the matching target drifts.
    def self.commit_plan_for(meeting_id:, import_rows:, snapshot:)
      validate_snapshot_shape!(snapshot)

      reconciler = new(meeting_id:, import_rows:)
      expected = reconciler.discover.index_by { |candidate| candidate['id'].to_i }
      stored = Array(snapshot['candidates'])

      validate_stored_candidates!(expected, stored)

      stored.each_with_object({ 'delete_ids' => [], 'merge_targets' => {} }) do |candidate, plan|
        next unless candidate['selected'] == true

        id = candidate['id'].to_i
        current = expected[id]
        if candidate['merge'] == true && current['merge_target_import_key'].present?
          plan['merge_targets'][id] = merge_target_snapshot(current)
        else
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

    def self.merge_target_snapshot(current)
      {
        'import_key' => current['merge_target_import_key'],
        'program_key' => current['merge_target_program_key'],
        'meeting_program_id' => current['merge_target_meeting_program_id'],
        'swimmer_id' => current['merge_target_swimmer_id'],
        'team_id' => current['merge_target_team_id'],
        'timing' => current['merge_target_timing']
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
      candidate['selected'] == true && candidate['merge_target_import_key'].present?
    end

    def self.validate_snapshot_shape!(snapshot)
      return if snapshot.is_a?(Hash) && snapshot['version'].to_i == SNAPSHOT_VERSION && snapshot['candidates'].is_a?(Array)

      raise ArgumentError, 'Invalid individual-result overwrite snapshot'
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

    # Imported meeting_program_ids per (swimmer_id, team_id), indexed once.
    # Replaces the full import_rows scan that used to run per represented pair.
    def imported_program_ids_by_pair
      @imported_program_ids_by_pair ||= import_rows.each_with_object({}) do |row, index|
        next unless row.meeting_program_id.to_i.positive?

        key = [row.swimmer_id.to_i, row.team_id.to_i]
        (index[key] ||= Set.new) << row.meeting_program_id.to_i
      end
    end

    # All existing MIRs of the meeting for the represented swimmers/teams,
    # loaded in one query and grouped by (swimmer_id, team_id) instead of one
    # query per pair. The where clause may over-fetch unused pair combinations;
    # they simply land in buckets that are never read.
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

    # Import rows indexed by (swimmer_id, timing in hundredths) for merge-target
    # lookup. Replaces the full import_rows scan per candidate.
    def import_rows_by_swimmer_and_timing
      @import_rows_by_swimmer_and_timing ||= import_rows.group_by do |row|
        [row.swimmer_id.to_i, row.to_timing.to_hundredths]
      end
    end

    # Lap count per merge target, memoized by import_key so repeated candidates
    # sharing a target don't each issue their own COUNT query.
    def lap_count_for(import_key)
      (@lap_count_by_import_key ||= {})[import_key] ||=
        GogglesDb::DataImportLap.where(parent_import_key: import_key).count
    end

    def candidate_attributes(mir)
      candidate = mir_attributes(mir).merge(program_attributes(mir))
      merge_targets = find_merge_targets(candidate, import_rows)

      if merge_targets.size == 1
        candidate.merge!(merge_target_fields(merge_targets.first))
      else
        candidate.merge!(no_merge_target_fields(merge_targets.size > 1))
      end

      candidate['merge'] = self.class.default_merge?(candidate)
      candidate
    end

    def merge_target_fields(target)
      {
        'merge_available' => true,
        'merge_ambiguous' => false,
        'merge_target_import_key' => target.import_key,
        'merge_target_program_key' => target.meeting_program_key,
        'merge_target_meeting_program_id' => target.meeting_program_id,
        'merge_target_swimmer_id' => target.swimmer_id,
        'merge_target_team_id' => target.team_id,
        'merge_target_timing' => target.to_timing.to_s,
        'merge_target_lap_count' => lap_count_for(target.import_key)
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
        'merge_target_lap_count' => 0
      }
    end

    def mir_attributes(mir) # rubocop:disable Metrics/AbcSize
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

    def find_merge_targets(candidate, _import_rows)
      candidate_timing = Timing.new(
        minutes: candidate['minutes'].to_i,
        seconds: candidate['seconds'].to_i,
        hundredths: candidate['hundredths'].to_i
      ).to_hundredths

      bucket = import_rows_by_swimmer_and_timing[[candidate['swimmer_id'].to_i, candidate_timing]] || []
      matches = bucket.select { |row| merge_match?(row, candidate, candidate_timing) }
      matches.sort_by { |row| row.import_key.to_s }
    end

    def merge_match?(row, candidate, candidate_timing)
      row.swimmer_id.to_i == candidate['swimmer_id'].to_i &&
        row.to_timing.to_hundredths == candidate_timing &&
        row.meeting_program_key.to_s != candidate['meeting_program_key'].to_s &&
        row.meeting_individual_result_id.to_i != candidate['id'].to_i
    end

    def sort_key(candidate)
      [candidate['session_order'].to_i, candidate['event_code'].to_s, candidate['category_code'].to_s,
       candidate['gender_code'].to_s, candidate['rank'].to_i, candidate['id'].to_i]
    end
  end
end
