# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::DupBadgesForTeamChecker do
  let(:team) { GogglesDb::Team.find(1) }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:checker) { described_class.new(team:) }

      it 'creates an instance' do
        expect(checker).to be_a(described_class)
      end

      it 'stores the team' do
        expect(checker.team).to eq(team)
      end

      it 'initializes empty log' do
        expect(checker.log).to eq([])
      end

      it 'initializes empty report_data' do
        expect(checker.report_data).to eq({})
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when team is not a Team' do
        expect { described_class.new(team: 'not a team') }
          .to raise_error(ArgumentError, /Invalid Team!/)
      end

      it 'raises ArgumentError when team is nil' do
        expect { described_class.new(team: nil) }
          .to raise_error(ArgumentError, /Invalid Team!/)
      end
    end
  end

  describe '#run' do
    subject(:checker) { described_class.new(team:) }

    context 'when team has no badges' do
      before(:each) do
        allow(GogglesDb::Badge).to receive(:where).with(team_id: team.id).and_return(GogglesDb::Badge.none)
      end

      it 'returns self' do
        expect(checker.run).to eq(checker)
      end

      it 'leaves report_data empty' do
        checker.run
        expect(checker.report_data).to eq({})
      end

      it 'logs that no swimmers were found' do
        checker.run
        expect(checker.log).to include(/Found 0 swimmers/)
      end
    end

    context 'when team has swimmers but no duplicates' do
      let(:season) { GogglesDb::Season.find(192) }
      let(:category_type) { season.category_types.where(relay: false).first }
      let(:team_affiliation) { GogglesDb::TeamAffiliation.find_by(season:, team:) }
      let(:swimmer) { FactoryBot.create(:swimmer) }

      before(:each) do
        FactoryBot.create(:badge, swimmer:, team:, team_affiliation:, season:, category_type:)
      end

      it 'returns self' do
        expect(checker.run).to eq(checker)
      end

      it 'leaves report_data empty (no duplicates)' do
        checker.run
        expect(checker.report_data).to eq({})
      end
    end

    context 'when team has swimmers with duplicate badges' do
      let(:season) { GogglesDb::Season.find(192) }
      let(:category_type) { season.category_types.where(relay: false).first }
      let(:team_affiliation) { GogglesDb::TeamAffiliation.find_by(season:, team:) }
      let(:other_ta) { FactoryBot.create(:team_affiliation, season:) }
      let(:other_team) { other_ta.team }
      let(:swimmer) { FactoryBot.create(:swimmer) }

      before(:each) do
        # Badge on target team
        FactoryBot.create(:badge, swimmer:, team:, team_affiliation:, season:, category_type:)
        # Duplicate badge on same season but different team (triggers duplicate detection)
        FactoryBot.create(:badge, swimmer:, team: other_team, team_affiliation: other_ta, season:, category_type:)
      end

      it 'returns self' do
        expect(checker.run).to eq(checker)
      end

      it 'populates report_data with the swimmer' do
        checker.run
        expect(checker.report_data.keys).to include(swimmer.id)
      end

      it 'includes all badges for the swimmer across all seasons' do
        checker.run
        badge_count = checker.report_data[swimmer.id][:badges].size
        expect(badge_count).to eq(2)
      end

      it 'orders badges by season_id then badge_id' do
        checker.run
        badges = checker.report_data[swimmer.id][:badges]
        expect(badges).to eq(badges.sort_by { |b| [b[:season_id], b[:badge_id]] })
      end

      it 'includes MIR count (may be 0)' do
        checker.run
        badges = checker.report_data[swimmer.id][:badges]
        badges.each do |badge|
          expect(badge).to have_key(:mir_count)
          expect(badge[:mir_count]).to be_a(Integer)
          expect(badge[:mir_count]).to be >= 0
        end
      end

      it 'includes required columns in each badge row' do
        checker.run
        badges = checker.report_data[swimmer.id][:badges]
        expect(badges).to all have_key(:season_id).and have_key(:badge_id)
          .and have_key(:team_id).and have_key(:team_affiliation_id)
          .and have_key(:team_name).and have_key(:mir_count)
      end
    end
  end

  describe '#display_report' do
    subject(:checker) { described_class.new(team:) }

    context 'when report_data is empty' do
      it 'outputs a message that no duplicates were found' do
        expect { checker.display_report }.to output(/No swimmers with duplicate badges found/).to_stdout
      end
    end

    context 'when report_data has results' do
      let(:season) { GogglesDb::Season.find(192) }
      let(:category_type) { season.category_types.where(relay: false).first }
      let(:team_affiliation) { GogglesDb::TeamAffiliation.find_by(season:, team:) }
      let(:other_ta) { FactoryBot.create(:team_affiliation, season:) }
      let(:other_team) { other_ta.team }
      let(:swimmer) { FactoryBot.create(:swimmer) }

      before(:each) do
        FactoryBot.create(:badge, swimmer:, team:, team_affiliation:, season:, category_type:)
        FactoryBot.create(:badge, swimmer:, team: other_team, team_affiliation: other_ta, season:, category_type:)
        checker.run
      end

      it 'outputs to stdout without raising' do
        expect { checker.display_report }.to output.to_stdout
      end

      it 'outputs table header' do
        expect { checker.display_report }.to output(/season_id.*badge_id.*team_id/).to_stdout
      end

      it 'outputs swimmer label' do
        expect { checker.display_report }.to output(/Swimmer:/).to_stdout
      end
    end
  end
end
