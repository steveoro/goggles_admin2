# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::TeamInMeeting do
  # Find a meeting with MIRs from multiple teams (for realistic test data)
  let(:meeting_with_multiple_teams) do
    # Find a meeting that has MIRs from at least 2 different teams
    meeting_id = GogglesDb::MeetingIndividualResult
                 .joins(meeting_program: { meeting_event: :meeting_session })
                 .select('meeting_sessions.meeting_id')
                 .group('meeting_sessions.meeting_id')
                 .having('COUNT(DISTINCT meeting_individual_results.team_id) > 1')
                 .limit(1)
                 .pick('meeting_sessions.meeting_id')
    GogglesDb::Meeting.find(meeting_id)
  end

  # Get two different teams from the meeting's results
  let(:team_ids_in_meeting) do
    GogglesDb::MeetingIndividualResult
      .joins(meeting_program: { meeting_event: :meeting_session })
      .where(meeting_sessions: { meeting_id: meeting_with_multiple_teams.id })
      .distinct
      .pluck(:team_id)
      .first(2)
  end

  let(:src_team) { GogglesDb::Team.find(team_ids_in_meeting.first) }
  let(:dest_team) { GogglesDb::Team.find(team_ids_in_meeting.second) }
  let(:meeting) { meeting_with_multiple_teams }
  let(:season) { meeting.season }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

      it 'creates an instance' do
        expect(merger).to be_a(described_class)
      end

      it 'stores the meeting' do
        expect(merger.meeting).to eq(meeting)
      end

      it 'stores the source team' do
        expect(merger.src_team).to eq(src_team)
      end

      it 'stores the destination team' do
        expect(merger.dest_team).to eq(dest_team)
      end

      it 'resolves the season from meeting' do
        expect(merger.season).to eq(season)
      end

      it 'initializes empty sql_log' do
        expect(merger.sql_log).to eq([])
      end

      it 'resolves destination TeamAffiliation' do
        expect(merger.dest_ta).to be_a(GogglesDb::TeamAffiliation)
        expect(merger.dest_ta.team_id).to eq(dest_team.id)
        expect(merger.dest_ta.season_id).to eq(season.id)
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when meeting is not a Meeting' do
        expect { described_class.new(meeting: 'not a meeting', src_team:, dest_team:) }
          .to raise_error(ArgumentError, /must be a Meeting/)
      end

      it 'raises ArgumentError when src_team is not a Team' do
        expect { described_class.new(meeting:, src_team: 'not a team', dest_team:) }
          .to raise_error(ArgumentError, /must be a Team/)
      end

      it 'raises ArgumentError when dest_team is not a Team' do
        expect { described_class.new(meeting:, src_team:, dest_team: 'not a team') }
          .to raise_error(ArgumentError, /must be a Team/)
      end

      it 'raises ArgumentError when source and destination are identical' do
        expect { described_class.new(meeting:, src_team:, dest_team: src_team) }
          .to raise_error(ArgumentError, /Identical source and destination/)
      end

      it 'raises ArgumentError when dest team has no TeamAffiliation for the season' do
        # Find a team that has no affiliation in this season
        unaffiliated_team = GogglesDb::Team
                            .where.not(id: GogglesDb::TeamAffiliation.where(season_id: season.id).select(:team_id))
                            .first
        skip('No unaffiliated team found in test DB') unless unaffiliated_team

        expect { described_class.new(meeting:, src_team:, dest_team: unaffiliated_team) }
          .to raise_error(ArgumentError, /has no TeamAffiliation/)
      end
    end
  end

  describe 'verification query accessors' do
    subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

    describe '#src_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.src_laps).to be_an(ActiveRecord::Relation)
      end

      it 'returns laps only for the source team' do
        merger.src_laps.each do |lap|
          expect(lap.team_id).to eq(src_team.id)
        end
      end
    end

    describe '#dest_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.dest_laps).to be_an(ActiveRecord::Relation)
      end

      it 'returns laps only for the destination team' do
        merger.dest_laps.each do |lap|
          expect(lap.team_id).to eq(dest_team.id)
        end
      end
    end

    describe '#src_mirs' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.src_mirs).to be_an(ActiveRecord::Relation)
      end

      it 'returns MIRs only for the source team' do
        expect(merger.src_mirs.count).to be >= 0
        merger.src_mirs.each do |mir|
          expect(mir.team_id).to eq(src_team.id)
        end
      end
    end

    describe '#dest_mirs' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.dest_mirs).to be_an(ActiveRecord::Relation)
      end

      it 'returns MIRs only for the destination team' do
        merger.dest_mirs.each do |mir|
          expect(mir.team_id).to eq(dest_team.id)
        end
      end
    end

    describe '#src_relay_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.src_relay_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#dest_relay_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.dest_relay_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#src_mrrs' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.src_mrrs).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#dest_mrrs' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.dest_mrrs).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#mir_badges_to_update' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.mir_badges_to_update).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#mrs_badges_to_update' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.mrs_badges_to_update).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#conflicting_badges' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.conflicting_badges).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#duplicate_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.duplicate_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#duplicate_relay_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(merger.duplicate_relay_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#duplicate_mrrs' do
      it 'returns an Array' do
        expect(merger.duplicate_mrrs).to be_an(Array)
      end
    end
  end

  describe '#display_report' do
    subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

    it 'outputs to stdout without raising' do
      expect { merger.display_report }.to output.to_stdout
    end

    it 'includes meeting information in output' do
      expect { merger.display_report }.to output(/Meeting.*#{meeting.id}/).to_stdout
    end

    it 'includes team information in output' do
      expect { merger.display_report }.to output(/Source team.*#{src_team.id}/).to_stdout
    end
  end

  describe '#prepare' do
    subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

    before(:each) { merger.prepare }

    it 'populates sql_log' do
      expect(merger.sql_log).not_to be_empty
    end

    it 'starts with transaction control' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('SET AUTOCOMMIT = 0')
      expect(sql).to include('START TRANSACTION')
    end

    it 'ends with COMMIT' do
      expect(merger.sql_log.last).to eq('COMMIT;')
    end

    it 'includes badge update SQL (Step 0a)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 0a')
      expect(sql).to include('UPDATE badges')
    end

    it 'includes lap update SQL (Step 1a)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 1a')
      expect(sql).to include('UPDATE laps')
    end

    it 'includes MIR update SQL (Step 1b)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 1b')
      expect(sql).to include('UPDATE meeting_individual_results')
    end

    it 'includes relay_lap update SQL (Step 2a)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 2a')
      expect(sql).to include('UPDATE relay_laps')
    end

    it 'includes MRR update SQL (Step 2b)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 2b')
      expect(sql).to include('UPDATE meeting_relay_results')
    end

    it 'includes duplicate lap deletion SQL (Step 3)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 3')
      expect(sql).to include('DELETE l1')
    end

    it 'includes duplicate MIR deletion SQL (Step 4)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 4')
      expect(sql).to include('DELETE mir1')
    end

    it 'includes duplicate relay_lap deletion SQL (Step 5)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 5')
      expect(sql).to include('DELETE rl1')
    end

    it 'includes duplicate MRS deletion SQL (Step 6)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 6')
      expect(sql).to include('DELETE mrs1')
    end

    it 'includes duplicate MRR deletion SQL (Step 7)' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Step 7')
      expect(sql).to include('DELETE mrr1')
    end

    it 'uses correct team IDs in SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include("team_id = #{dest_team.id}")
      expect(sql).to include("team_id = #{src_team.id}")
    end

    it 'uses correct meeting ID in SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include("meeting_id = #{meeting.id}")
    end

    it 'prevents multiple runs' do
      initial_log_size = merger.sql_log.size
      merger.prepare
      expect(merger.sql_log.size).to eq(initial_log_size)
    end
  end

  describe 'SQL generation with source TeamAffiliation' do
    subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

    context 'when source team has TeamAffiliation for the season' do
      before(:each) { merger.prepare }

      it 'includes TA restoration SQL' do
        if merger.src_ta.present?
          sql = merger.sql_log.join("\n")
          expect(sql).to include('UPDATE team_affiliations')
          expect(sql).to include("WHERE id=#{merger.src_ta.id}")
        end
      end

      it 'uses correct TA IDs in MIR updates' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include("team_affiliation_id = #{merger.dest_ta.id}")
      end
    end
  end

  describe 'full_report option' do
    context 'when full_report is false (default)' do
      subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

      it 'sets full_report to false' do
        expect(merger.full_report).to be false
      end
    end

    context 'when full_report is true' do
      subject(:merger) { described_class.new(meeting:, src_team:, dest_team:, full_report: true) }

      it 'sets full_report to true' do
        expect(merger.full_report).to be true
      end

      it 'outputs to stdout without raising' do
        expect { merger.display_report }.to output.to_stdout
      end
    end
  end

  describe '#badge_merge_pairs' do
    subject(:merger) { described_class.new(meeting:, src_team:, dest_team:) }

    it 'returns an Array' do
      expect(merger.badge_merge_pairs).to be_an(Array)
    end

    it 'returns pairs of badge IDs' do
      merger.badge_merge_pairs.each do |pair|
        expect(pair).to be_an(Array)
        expect(pair.size).to eq(2)
      end
    end
  end
end
