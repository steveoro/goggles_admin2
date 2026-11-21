# frozen_string_literal: true

require 'rails_helper'

# = Legacy team-score baseline (Phase 02, step 1)
#
# Runs the legacy pair (Import::MacroSolver#solve + Import::MacroCommitter#commit_all) on the
# trimmed PDF-derived LT2 fixture inside the example transaction (nothing survives the example)
# and compares the resulting meeting_team_scores with the frozen legacy output in
# spec/fixtures/import/team_scores_legacy_expected.json.
#
# The frozen JSON is the parity reference for the v2 port
# (spec/strategies/import/committers/meeting_team_score_parity_spec.rb) and must outlive
# the legacy classes: this spec goes away together with MacroSolver/MacroCommitter.
#
# Regenerate the frozen file (only while the legacy classes still exist) with:
#   UPDATE_LEGACY_BASELINE=1 bundle exec rspec spec/strategies/import/team_scores_legacy_baseline_spec.rb
#
RSpec.describe 'Legacy team-score baseline', type: :strategy do # rubocop:disable RSpec/DescribeClass
  let(:fixture_path) { Rails.root.join('spec/fixtures/import/pdf-teamrank-lt2.json') }
  let(:expected_path) { Rails.root.join('spec/fixtures/import/team_scores_legacy_expected.json') }
  let(:data_hash) { JSON.parse(File.read(fixture_path)) }
  let(:season_id) { data_hash['season_id'] }

  # Meeting-independent attributes of a committed MeetingTeamScore (the meeting is new on each run).
  def frozen_attributes_for(row)
    {
      'rank' => row.rank,
      'team_id' => row.team_id,
      'team_affiliation_id' => row.team_affiliation_id,
      'season_id' => row.season_id,
      'sum_individual_points' => row.sum_individual_points.to_f,
      'sum_relay_points' => row.sum_relay_points.to_f,
      'sum_team_points' => row.sum_team_points.to_f,
      'meeting_points' => row.meeting_points.to_f,
      'meeting_relay_points' => row.meeting_relay_points.to_f,
      'meeting_team_points' => row.meeting_team_points.to_f,
      'season_points' => row.season_points.to_f,
      'season_relay_points' => row.season_relay_points.to_f,
      'season_team_points' => row.season_team_points.to_f
    }
  end

  it 'commits the overall team ranking as the frozen legacy output', :aggregate_failures do
    solver = Import::MacroSolver.new(season_id:, data_hash:)
    # The legacy team-score rows bind only 'team' & 'team_affiliation' (no 'meeting' binding), so
    # MacroCommitter#commit_team_scores fails validation on a brand-new meeting: save the solved
    # meeting first, so that the full solve below finds it and the score rows carry its ID.
    solver.map_meeting_and_sessions
    solver.data['meeting'].row.save!
    solver.solve
    committer = Import::MacroCommitter.new(solver:)
    committer.commit_all

    meeting = committer.data['meeting']
    expect(meeting).to be_a(GogglesDb::Meeting)
    expect(meeting.id).to be_positive

    rows = GogglesDb::MeetingTeamScore.where(meeting_id: meeting.id).order(:rank).map { |row| frozen_attributes_for(row) }
    expect(rows.size).to eq(5)

    if ENV['UPDATE_LEGACY_BASELINE'].present?
      payload = {
        '_meta' => {
          'fixture' => 'spec/fixtures/import/pdf-teamrank-lt2.json',
          'generator' => 'Import::MacroSolver#solve + Import::MacroCommitter#commit_all',
          'note' => 'meeting_team_scores committed by the legacy flow; meeting_id omitted (new on each run)'
        },
        'team_scores' => rows
      }
      File.write(expected_path, "#{JSON.pretty_generate(payload)}\n")
    end

    expect(rows).to eq(JSON.parse(File.read(expected_path))['team_scores'])
  end
end
