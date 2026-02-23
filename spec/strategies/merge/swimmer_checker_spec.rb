# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::SwimmerChecker do
  # Use two existing swimmers that share at least one season for meaningful tests
  let(:source) { GogglesDb::Swimmer.find(142) }
  let(:dest)   { GogglesDb::Swimmer.find(23) }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:checker) { described_class.new(source:, dest:) }

      it 'creates an instance' do
        expect(checker).to be_a(described_class)
      end

      it 'decorates the source swimmer' do
        expect(checker.source).to respond_to(:display_label)
      end

      it 'decorates the destination swimmer' do
        expect(checker.dest).to respond_to(:display_label)
      end

      it 'initializes empty log, errors and warnings' do
        expect(checker.log).to eq([])
        expect(checker.errors).to eq([])
        expect(checker.warnings).to eq([])
      end

      it 'initializes empty badge collections' do
        expect(checker.src_only_badges).to eq([])
        expect(checker.shared_badges).to eq({})
        expect(checker.orphan_src_badges).to eq([])
      end

      it 'initializes empty sub-entity collections' do
        expect(checker.src_only_mirs).to eq([])
        expect(checker.src_only_mrss).to eq([])
        expect(checker.src_only_laps).to eq([])
        expect(checker.src_only_mes).to eq([])
        expect(checker.src_only_mres).to eq([])
        expect(checker.src_only_mev_res).to eq([])
        expect(checker.src_only_mrel_res).to eq([])
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when source is not a Swimmer' do
        expect { described_class.new(source: 'not a swimmer', dest:) }
          .to raise_error(ArgumentError, /must be Swimmers/)
      end

      it 'raises ArgumentError when dest is not a Swimmer' do
        expect { described_class.new(source:, dest: 'not a swimmer') }
          .to raise_error(ArgumentError, /must be Swimmers/)
      end
    end
  end

  describe '#run' do
    subject(:checker) { described_class.new(source:, dest:) }

    it 'populates the log' do
      checker.run
      expect(checker.log).not_to be_empty
    end

    it 'returns a boolean' do
      expect(checker.run).to be(true).or be(false)
    end

    context 'when source and dest are identical' do
      let(:dest) { source }

      it 'reports an error' do
        checker.run
        expect(checker.errors).to include(/Identical/)
      end

      it 'returns false' do
        expect(checker.run).to be false
      end
    end
  end

  describe '#shared_badge_seasons' do
    subject(:checker) { described_class.new(source:, dest:) }

    it 'returns an array of Season instances' do
      checker.run
      expect(checker.shared_badge_seasons).to be_an(Array)
      expect(checker.shared_badge_seasons).to all be_a(GogglesDb::Season)
    end
  end

  describe 'badge pairing by team_id' do
    subject(:checker) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

    let(:season) { GogglesDb::Season.find(192) }
    let(:category_type) { season.category_types.where(relay: false).first }
    let(:team) { FactoryBot.create(:team) }
    let(:ta) { FactoryBot.create(:team_affiliation, team:, season:) }
    let(:src_swimmer) { FactoryBot.create(:swimmer) }
    let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

    before(:each) do
      FactoryBot.create(:badge, swimmer: src_swimmer, team:, team_affiliation: ta,
                                season:, category_type:)
      FactoryBot.create(:badge, swimmer: dest_swimmer, team:, team_affiliation: ta,
                                season:, category_type:)
    end

    it 'pairs shared badges by team_id' do
      checker.run
      expect(checker.shared_badges).not_to be_empty
      checker.shared_badges.each do |src_badge_id, dest_badge_id|
        src_badge = GogglesDb::Badge.find(src_badge_id)
        dest_badge = GogglesDb::Badge.find(dest_badge_id)
        expect(src_badge.team_id).to eq(dest_badge.team_id)
        expect(src_badge.season_id).to eq(dest_badge.season_id)
      end
    end

    it 'does not produce orphan badges for same-team pairs' do
      checker.run
      expect(checker.orphan_src_badges).to be_empty
    end

    context 'when source has a badge with a different team in the same season' do
      let(:other_team) { FactoryBot.create(:team) }
      let(:other_ta) { FactoryBot.create(:team_affiliation, team: other_team, season:) }

      before(:each) do
        FactoryBot.create(:badge, swimmer: src_swimmer, team: other_team, team_affiliation: other_ta,
                                  season:, category_type:)
      end

      it 'places the unmatched badge in orphan_src_badges' do
        checker.run
        expect(checker.orphan_src_badges).not_to be_empty
        orphan_badge = GogglesDb::Badge.find(checker.orphan_src_badges.first)
        expect(orphan_badge.team_id).to eq(other_team.id)
      end

      it 'still pairs the matching badge correctly' do
        checker.run
        expect(checker.shared_badges).not_to be_empty
      end
    end
  end

  describe '#display_report' do
    subject(:checker) { described_class.new(source:, dest:) }

    before(:each) { checker.run }

    it 'outputs to stdout' do
      expect { checker.display_report }.to output.to_stdout
    end
  end
end
