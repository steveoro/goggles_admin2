# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::MeetingIndividualResult do
  let(:stats) { { mirs_created: 0, mirs_updated: 0, errors: [] } }
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/meeting-individual-result-committer-spec.log') }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats: stats, logger: logger, sql_log: sql_log) }
  let(:existing_mir) { FactoryBot.create(:meeting_individual_result) }
  let(:season_id) { existing_mir.meeting_program.meeting.season_id }

  before(:each) do
    FactoryBot.create(:team_affiliation, team_id: existing_mir.team_id, season_id: season_id)
  end

  def import_row(point_attributes)
    FactoryBot.build(
      :data_import_meeting_individual_result,
      meeting_individual_result_id: existing_mir.id,
      meeting_program_id: existing_mir.meeting_program_id,
      swimmer_id: existing_mir.swimmer_id,
      team_id: existing_mir.team_id,
      badge_id: existing_mir.badge_id,
      rank: existing_mir.rank.to_i + 1,
      minutes: existing_mir.minutes,
      seconds: existing_mir.seconds,
      hundredths: existing_mir.hundredths,
      **point_attributes
    )
  end

  describe '#commit' do
    it 'preserves existing point fields when imported values are zero' do
      existing_mir.update!(standard_points: 800.25, meeting_points: 12.5, goggle_cup_points: 7.75)

      committer.commit(
        import_row(standard_points: 0, meeting_points: 0, goggle_cup_points: 0),
        season_id: season_id
      )

      expect(existing_mir.reload).to have_attributes(
        standard_points: 800.25,
        meeting_points: 12.5,
        goggle_cup_points: 7.75
      )
      expect(sql_log.join).not_to include('standard_points', 'meeting_points', 'goggle_cup_points')
    end

    it 'updates all point fields when imported values are positive' do
      existing_mir.update!(standard_points: 700.0, meeting_points: 10.0, goggle_cup_points: 5.0)

      committer.commit(
        import_row(standard_points: 810.5, meeting_points: 15.25, goggle_cup_points: 9.75),
        season_id: season_id
      )

      expect(existing_mir.reload).to have_attributes(
        standard_points: 810.5,
        meeting_points: 15.25,
        goggle_cup_points: 9.75
      )
      expect(sql_log.join).to include('`standard_points`=810.5', '`meeting_points`=15.25', '`goggle_cup_points`=9.75')
    end
  end
end
