# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::SwimmerInBadge do
  # Find a badge that has MIRs, then pick a different swimmer that has no badge
  # for the same season/team (to avoid intentional duplicate collisions).
  let(:badge_with_mirs) do
    GogglesDb::MeetingIndividualResult
      .joins(:badge)
      .limit(200).sample
      &.badge
  end

  let(:season) { badge_with_mirs.season }

  let(:new_swimmer) do
    occupied_swimmer_ids = GogglesDb::Badge
                           .where(season_id: season.id, team_id: badge_with_mirs.team_id)
                           .select(:swimmer_id)
    GogglesDb::Swimmer
      .where.not(id: occupied_swimmer_ids)
      .limit(200).sample
  end

  before(:each) do
    skip('No suitable badge with MIRs found in test DB') unless badge_with_mirs
    skip('No suitable destination swimmer found in test DB') unless new_swimmer
  end

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_swimmer:) }

      it 'creates an instance' do
        expect(fixer).to be_a(described_class)
      end

      it 'stores the badges' do
        expect(fixer.badges).to eq([badge_with_mirs])
      end

      it 'stores the new_swimmer' do
        expect(fixer.new_swimmer).to eq(new_swimmer)
      end

      it 'derives the season from the badge' do
        expect(fixer.season).to eq(season)
      end

      it 'initializes empty sql_log' do
        expect(fixer.sql_log).to eq([])
      end

      it 'initializes the badge_batch' do
        expect(fixer.badge_batch).to be_an(ActiveRecord::Relation)
        expect(fixer.badge_batch).to include(badge_with_mirs)
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when badges is not an Array' do
        expect { described_class.new(badges: 'not an array', new_swimmer:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when badges is empty' do
        expect { described_class.new(badges: [], new_swimmer:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when badges contains non-Badge objects' do
        expect { described_class.new(badges: ['not a badge'], new_swimmer:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when new_swimmer is not a Swimmer' do
        expect { described_class.new(badges: [badge_with_mirs], new_swimmer: 'not a swimmer') }
          .to raise_error(ArgumentError, /must be a Swimmer/)
      end

      it 'raises ArgumentError when badge already belongs to the destination swimmer' do
        same_swimmer = badge_with_mirs.swimmer
        expect { described_class.new(badges: [badge_with_mirs], new_swimmer: same_swimmer) }
          .to raise_error(ArgumentError, /already belong to the destination swimmer/)
      end
    end
  end

  describe 'accessor methods' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_swimmer:) }

    describe '#affected_mirs' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_mirs).to be_an(ActiveRecord::Relation)
      end

      it 'returns MIRs linked to badge_batch badges' do
        fixer.affected_mirs.each do |mir|
          expect(fixer.badge_batch.pluck(:id)).to include(mir.badge_id)
        end
      end
    end

    describe '#affected_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_mrss' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_mrss).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_relay_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_relay_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_entries' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_entries).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_reservations).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_event_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_event_reservations).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_relay_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_relay_reservations).to be_an(ActiveRecord::Relation)
      end
    end
  end

  describe '#display_report' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_swimmer:) }

    it 'outputs to stdout without raising' do
      expect { fixer.display_report }.to output.to_stdout
    end

    it 'includes season information in output' do
      expect { fixer.display_report }.to output(/Season.*#{season.id}/).to_stdout
    end

    it 'includes new swimmer information in output' do
      expect { fixer.display_report }.to output(/New.*correct.*swimmer.*#{new_swimmer.id}/).to_stdout
    end

    it 'includes badge count in output' do
      expect { fixer.display_report }.to output(/Badges to update/).to_stdout
    end
  end

  describe '#prepare' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_swimmer:) }

    before(:each) { fixer.prepare }

    it 'populates sql_log' do
      expect(fixer.sql_log).not_to be_empty
    end

    it 'starts with transaction control' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('SET AUTOCOMMIT = 0')
      expect(sql).to include('START TRANSACTION')
    end

    it 'ends with COMMIT' do
      expect(fixer.sql_log.last).to eq('COMMIT;')
    end

    it 'includes badge update SQL (Step 1)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 1')
      expect(sql).to include('UPDATE badges')
      expect(sql).to include("swimmer_id = #{new_swimmer.id}")
    end

    it 'includes MIR update SQL (Step 2)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 2')
      expect(sql).to include('UPDATE meeting_individual_results')
    end

    it 'includes lap update SQL (Step 3)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 3')
      expect(sql).to include('UPDATE laps')
    end

    it 'includes MRS update SQL (Step 4)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 4')
      expect(sql).to include('UPDATE meeting_relay_swimmers')
    end

    it 'includes entry update SQL (Step 6)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 6')
      expect(sql).to include('UPDATE meeting_entries')
    end

    it 'includes reservation update SQL (Steps 7-9)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 7')
      expect(sql).to include('UPDATE meeting_event_reservations')
      expect(sql).to include('Step 8')
      expect(sql).to include('UPDATE meeting_relay_reservations')
      expect(sql).to include('Step 9')
      expect(sql).to include('UPDATE meeting_reservations')
    end

    it 'uses correct swimmer and badge IDs in SQL' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include("swimmer_id = #{new_swimmer.id}")
      expect(sql).to include(badge_with_mirs.id.to_s)
    end

    it 'prevents multiple runs' do
      initial_log_size = fixer.sql_log.size
      fixer.prepare
      expect(fixer.sql_log.size).to eq(initial_log_size)
    end
  end

  describe 'duplicate badge detection' do
    # Create a scenario where the destination swimmer already has a badge on the same team/season.
    let(:team_with_two_swimmers) do
      GogglesDb::Badge
        .group(:team_id, :season_id)
        .having('COUNT(DISTINCT swimmer_id) > 1')
        .limit(1)
        .pick(:team_id, :season_id)
    end

    it 'populates errors when duplicate badges exist' do
      skip('No team/season with multiple swimmers found in test DB') unless team_with_two_swimmers

      team_id, season_id = team_with_two_swimmers

      src_badge = GogglesDb::Badge.find_by(
        team_id:,
        season_id:
      )
      dest_badge = GogglesDb::Badge.where(
        team_id:,
        season_id:
      ).where.not(swimmer_id: src_badge&.swimmer_id).first
      dest_swimmer = dest_badge&.swimmer
      skip('No suitable destination swimmer found for duplicate test') unless src_badge && dest_swimmer

      fixer = described_class.new(badges: [src_badge], new_swimmer: dest_swimmer)
      expect(fixer.errors).not_to be_empty
    end

    it 'raises on prepare when duplicate badges exist' do
      skip('No team/season with multiple swimmers found in test DB') unless team_with_two_swimmers

      team_id, season_id = team_with_two_swimmers

      src_badge = GogglesDb::Badge.find_by(
        team_id:,
        season_id:
      )
      dest_badge = GogglesDb::Badge.where(
        team_id:,
        season_id:
      ).where.not(swimmer_id: src_badge&.swimmer_id).first
      dest_swimmer = dest_badge&.swimmer
      skip('No suitable destination swimmer found for duplicate test') unless src_badge && dest_swimmer

      fixer = described_class.new(badges: [src_badge], new_swimmer: dest_swimmer)
      expect { fixer.prepare }.to raise_error(RuntimeError, /Duplicate badges detected/)
    end
  end

  describe 'multiple badges input' do
    # Find two badges from the same season/team and same (wrong) swimmer.
    let(:two_badges_same_season) do
      season_id = badge_with_mirs.season_id
      team_id = badge_with_mirs.team_id
      GogglesDb::Badge
        .where(season_id:, team_id:, swimmer_id: badge_with_mirs.swimmer_id)
        .limit(2)
        .to_a
    end

    it 'accepts multiple badges' do
      skip('Not enough badges found for multi-badge test') if two_badges_same_season.size < 2

      fixer = described_class.new(badges: two_badges_same_season, new_swimmer:)
      expect(fixer.badge_batch.count).to be >= 2
      two_badges_same_season.each do |badge|
        expect(fixer.badge_batch).to include(badge)
      end
    end
  end
end
