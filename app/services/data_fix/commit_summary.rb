# frozen_string_literal: true

module DataFix
  #
  # = DataFix::CommitSummary
  #
  # Read model of the commit summary page (and of the 'summary' JSON stored on Ops::CommitReport): how the meeting
  # was matched, existing / new counts per entity, the confidently-new teams and swimmers (DataFix::ReviewRules),
  # results to create or update, overwrite deletions and team scores. Reads only the phase files and the staging rows.
  #
  class CommitSummary
    Row = Data.define(:key, :existing, :new)
    LIST_LIMIT = 50

    attr_reader :pipeline, :summary

    def initialize(pipeline:, summary: nil)
      @pipeline = pipeline
      @summary = summary || pipeline.summary
    end

    def meeting
      data = pipeline.phase_data(1)
      { 'id' => data['id'], 'name' => data['name'], 'code' => data['code'], 'header_date' => data['header_date'],
        'matched_by' => matched_by(data) }
    end

    # 'fin' (FIN event id), 'operator' (meeting chosen in Step 1), 'other' (name match), or nil (new meeting).
    def matched_by(data = pipeline.phase_data(1))
      return nil if data['id'].blank?
      return 'fin' if DataFix::ReviewRules.meeting_matched_by_fin?(data)
      return 'operator' if pipeline.phase_meta(1)['operator_edit'].present?

      'other'
    end

    def rows
      p1 = pipeline.phase_data(1)
      p2 = pipeline.phase_data(2)
      p3 = pipeline.phase_data(3)
      events = Array(pipeline.phase_data(4)['sessions']).flat_map { |session| Array(session['events']) }
      [
        split(:sessions, Array(p1['meeting_session'])) { |row| row['id'].present? },
        split(:teams, Array(p2['teams'])) { |row| row['team_id'].present? },
        split(:swimmers, Array(p3['swimmers'])) { |row| row['swimmer_id'].present? },
        split(:badges, Array(p3['badges'])) { |row| row['badge_id'].present? },
        split(:events, events) { |row| row['id'].present? || row['meeting_event_id'].present? },
        Row.new(key: :results, existing: staged[:mir_existing] + staged[:mrr_existing], new: staged[:mir_new] + staged[:mrr_new])
      ]
    end

    delegate :new_teams, to: :summary
    delegate :new_swimmers, to: :summary

    def overwrite_deletions
      overwrite = pipeline.phase_meta(5)['individual_result_overwrite']
      return 0 unless overwrite.is_a?(Hash) && overwrite['enabled'] == true

      Array(overwrite.dig('snapshot', 'candidates')).count { |candidate| candidate['selected'] == true }
    end

    def team_scores = Array(pipeline.phase_data(2)['team_scores'])

    delegate :result_free?, to: :pipeline

    def to_h
      { 'meeting' => meeting, 'stage' => summary.stage,
        'rows' => rows.to_h { |row| [row.key.to_s, { 'existing' => row.existing, 'new' => row.new }] },
        'new_teams' => new_teams.first(LIST_LIMIT), 'new_swimmers' => new_swimmers.first(LIST_LIMIT),
        'new_teams_count' => new_teams.size, 'new_swimmers_count' => new_swimmers.size,
        'overwrite_deletions' => overwrite_deletions, 'team_scores' => team_scores.size, 'result_free' => result_free? }
    end

    private

    def split(key, list, &)
      existing = list.count(&)
      Row.new(key:, existing:, new: list.size - existing)
    end

    def staged
      @staged ||= begin
        mirs = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: pipeline.source_path)
        mrrs = GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: pipeline.source_path)
        { mir_existing: mirs.where.not(meeting_individual_result_id: nil).count, mir_new: mirs.where(meeting_individual_result_id: nil).count,
          mrr_existing: mrrs.where.not(meeting_relay_result_id: nil).count, mrr_new: mrrs.where(meeting_relay_result_id: nil).count }
      end
    end
  end
end
