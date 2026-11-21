# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::MeetingTeamScore do
  let(:stats) { { team_scores_created: 0, team_scores_updated: 0, team_scores_skipped: 0, errors: [] } }
  let(:logger) { Import::PhaseCommitLogger.new(log_path: File.join(Dir.tmpdir, 'meeting_team_score_committer_test.log')) }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats:, logger:, sql_log:) }

  let(:team_affiliation) { FactoryBot.create(:team_affiliation) }
  let(:team) { team_affiliation.team }
  let(:season) { team_affiliation.season }
  let(:meeting) { FactoryBot.create(:meeting, season:) }
  let(:score_hash) { { 'team_key' => team.name, 'rank' => 3, 'ind_score' => 32_368.92, 'overall_score' => 33_118.92 } }

  def commit_score(hash = score_hash)
    committer.commit(hash, meeting_id: meeting.id, season_id: season.id, team_id: team.id,
                           team_affiliation_id: team_affiliation.id)
  end

  describe '#commit' do
    it 'inserts a new row with the legacy attribute mapping', :aggregate_failures do
      row_id = commit_score
      row = GogglesDb::MeetingTeamScore.find(row_id)

      expect(row).to have_attributes(
        meeting_id: meeting.id, season_id: season.id, team_id: team.id, team_affiliation_id: team_affiliation.id, rank: 3
      )
      expect(row.sum_individual_points.to_f).to eq(32_368.92)
      expect(row.sum_relay_points.to_f).to eq(750.0)
      expect(row.sum_team_points.to_f).to eq(33_118.92)
      expect(row.meeting_points.to_f).to eq(32_368.92)
      expect(row.meeting_relay_points.to_f).to eq(750.0)
      expect(row.meeting_team_points.to_f).to eq(33_118.92)
      expect([row.season_points, row.season_relay_points, row.season_team_points].map(&:to_f)).to eq([0.0, 0.0, 0.0])
      expect(stats).to include(team_scores_created: 1, team_scores_updated: 0)
      expect(sql_log.size).to eq(1)
      expect(sql_log.first).to start_with('INSERT INTO `meeting_team_scores`')
      expect(logger.entries.last).to include(entity_type: 'MeetingTeamScore', entity_id: row_id, action: 'created')
    end

    it 'updates the existing row found by (meeting_id, team_id), logging only the changed columns', :aggregate_failures do
      existing = FactoryBot.create(:meeting_team_score, meeting:, team:, team_affiliation:, season:, rank: 9)

      row_id = commit_score

      expect(row_id).to eq(existing.id)
      expect(GogglesDb::MeetingTeamScore.where(meeting_id: meeting.id, team_id: team.id).count).to eq(1)
      expect(existing.reload.rank).to eq(3)
      expect(existing.sum_team_points.to_f).to eq(33_118.92)
      expect(stats).to include(team_scores_created: 0, team_scores_updated: 1)
      expect(sql_log.size).to eq(1)
      expect(sql_log.first).to start_with('UPDATE `meeting_team_scores`')
      expect(sql_log.first).to include('`rank`=3').and include("WHERE `id`=#{existing.id};")
      expect(sql_log.first).not_to include('`meeting_id`=')
    end

    it 'leaves an unchanged existing row alone' do
      first_id = commit_score
      sql_log.clear

      expect(commit_score).to eq(first_id)
      expect(sql_log).to be_empty
      expect(stats).to include(team_scores_created: 1, team_scores_updated: 0)
    end

    it 'records the validation error and re-raises on an invalid row' do
      expect do
        committer.commit(score_hash, meeting_id: nil, season_id: season.id, team_id: team.id,
                                     team_affiliation_id: team_affiliation.id)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(stats[:errors].first).to start_with("MeetingTeamScore error (#{team.name})")
    end
  end
end
