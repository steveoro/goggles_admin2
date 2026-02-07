# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::TeamChecker do
  # Use two existing teams with no swimmer overlap for basic tests
  let(:source) { GogglesDb::Team.find(1) }
  let(:dest)   { GogglesDb::Team.find(2) }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:checker) { described_class.new(source:, dest:) }

      it 'creates an instance' do
        expect(checker).to be_a(described_class)
      end

      it 'decorates the source team' do
        expect(checker.source).to respond_to(:display_label)
      end

      it 'decorates the destination team' do
        expect(checker.dest).to respond_to(:display_label)
      end

      it 'initializes empty log' do
        expect(checker.log).to eq([])
      end

      it 'computes season IDs' do
        expect(checker.src_season_ids).to be_an(Array)
        expect(checker.dest_season_ids).to be_an(Array)
        expect(checker.overall_season_ids).to be_an(Array)
        expect(checker.shared_season_ids).to be_an(Array)
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when source is not a Team' do
        expect { described_class.new(source: 'not a team', dest:) }
          .to raise_error(ArgumentError, /must be Teams/)
      end

      it 'raises ArgumentError when dest is not a Team' do
        expect { described_class.new(source:, dest: 'not a team') }
          .to raise_error(ArgumentError, /must be Teams/)
      end

      it 'raises ArgumentError when source and dest are identical' do
        expect { described_class.new(source:, dest: source) }
          .to raise_error(ArgumentError, /Identical/)
      end
    end
  end

  describe '#run' do
    subject(:checker) { described_class.new(source:, dest:) }

    it 'populates the log' do
      checker.run
      expect(checker.log).not_to be_empty
    end

    it 'prevents running more than once' do
      checker.run
      log_after_first_run = checker.log.dup
      checker.run
      expect(checker.log).to eq(log_after_first_run)
    end
  end

  # Use FactoryBot to create a shared-swimmer scenario (test DB has no natural ones)
  context 'with shared swimmers (FactoryBot data)' do
    subject(:checker) { described_class.new(source: src_team, dest: dest_team) }

    let(:season) { GogglesDb::Season.find(192) }
    let(:category_type) { season.category_types.where(relay: false).first }
    let(:src_ta) { FactoryBot.create(:team_affiliation, season:) }
    let(:dest_ta) { FactoryBot.create(:team_affiliation, season:) }
    let(:src_team) { src_ta.team }
    let(:dest_team) { dest_ta.team }
    let(:swimmer) { GogglesDb::Swimmer.limit(200).sample }

    let!(:src_badge) do
      FactoryBot.create(:badge, swimmer:, team: src_team, team_affiliation: src_ta,
                                season:, category_type:)
    end
    let!(:dest_badge) do
      FactoryBot.create(:badge, swimmer:, team: dest_team, team_affiliation: dest_ta,
                                season:, category_type:)
    end
    # An orphan badge on src_team (no counterpart on dest)
    let!(:orphan_badge) do
      FactoryBot.create(:badge, team: src_team, team_affiliation: src_ta,
                                season:, category_type:)
    end

    before(:each) { checker.run }

    describe '#shared_badge_couples_by_season' do
      it 'returns a Hash grouped by season_id' do
        result = checker.shared_badge_couples_by_season
        expect(result).to be_a(Hash)
        expect(result.keys).to include(season.id)
      end

      it 'contains badge couples for the shared swimmer' do
        couples = checker.shared_badge_couples_by_season[season.id]
        expect(couples).to be_an(Array)
        expect(couples.size).to be >= 1
        couple = couples.find { |c| c.first.swimmer_id == swimmer.id }
        expect(couple).to be_present
        expect(couple.first.team_id).to eq(src_team.id)
        expect(couple.last.team_id).to eq(dest_team.id)
      end

      it 'returns an empty hash when run has not been called' do
        fresh_checker = described_class.new(source: src_team, dest: dest_team)
        expect(fresh_checker.shared_badge_couples_by_season).to eq({})
      end
    end

    describe '#orphan_src_badges_by_season' do
      it 'returns a Hash grouped by season_id' do
        result = checker.orphan_src_badges_by_season
        expect(result).to be_a(Hash)
      end

      it 'excludes swimmers that appear in shared_badge_couples' do
        shared_swimmer_ids = checker.shared_badge_couples.map { |c| c.first.swimmer_id }
        checker.orphan_src_badges_by_season.each_value do |badges|
          badges.each do |badge|
            expect(shared_swimmer_ids).not_to include(badge.swimmer_id)
          end
        end
      end

      it 'contains only source-team badges' do
        checker.orphan_src_badges_by_season.each_value do |badges|
          badges.each do |badge|
            expect(badge.team_id).to eq(src_team.id)
          end
        end
      end

      it 'includes the orphan badge' do
        orphan_season_badges = checker.orphan_src_badges_by_season[season.id]
        expect(orphan_season_badges).to be_present
        expect(orphan_season_badges.map(&:id)).to include(orphan_badge.id)
      end
    end
  end

  describe '#display_report' do
    subject(:checker) { described_class.new(source:, dest:) }

    before(:each) { checker.run }

    it 'outputs to stdout without raising' do
      expect { checker.display_report }.to output.to_stdout
    end
  end

  describe '#src_entities / #dest_entities' do
    subject(:checker) { described_class.new(source:, dest:) }

    it 'returns an ActiveRecord Relation for source entities' do
      expect(checker.src_entities(GogglesDb::Badge)).to be_an(ActiveRecord::Relation)
    end

    it 'returns an ActiveRecord Relation for destination entities' do
      expect(checker.dest_entities(GogglesDb::Badge)).to be_an(ActiveRecord::Relation)
    end

    it 'memoizes the result' do
      first_call = checker.src_entities(GogglesDb::Badge)
      second_call = checker.src_entities(GogglesDb::Badge)
      expect(first_call).to equal(second_call)
    end
  end
end
