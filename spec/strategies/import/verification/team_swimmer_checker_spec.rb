# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Verification::TeamSwimmerChecker do
  let(:team) { FactoryBot.create(:team) }
  let(:other_team) { FactoryBot.create(:team) }
  let(:target_season) { FactoryBot.create(:season, begin_date: Time.zone.today - 1.month, end_date: Time.zone.today + 8.months) }
  let(:past_season) { FactoryBot.create(:season, begin_date: Time.zone.today - 13.months, end_date: Time.zone.today - 4.months) }

  let(:swimmer) { FactoryBot.create(:swimmer) }
  let(:swimmer2) { FactoryBot.create(:swimmer) }

  let(:category_type) { FactoryBot.create(:category_type, season: target_season) }
  let(:past_category_type) { FactoryBot.create(:category_type, season: past_season) }

  let(:target_ta) { FactoryBot.create(:team_affiliation, team: team, season: target_season) }
  let(:past_ta) { FactoryBot.create(:team_affiliation, team: team, season: past_season) }

  let(:phase3_data) do
    {
      'badges' => [
        { 'team_key' => 'TK1', 'swimmer_id' => swimmer.id },
        { 'team_key' => 'TK1', 'swimmer_id' => swimmer2.id }
      ],
      'swimmers' => [
        { 'swimmer_id' => swimmer.id, 'complete_name' => 'Test Swimmer One' },
        { 'swimmer_id' => swimmer2.id, 'complete_name' => 'Test Swimmer Two' }
      ]
    }
  end

  describe '#check' do
    context 'when params are invalid' do
      it 'returns empty result for blank team_key' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: '', candidate_team_id: team.id)
        expect(result[:confirmed]).to eq(0)
        expect(result[:swimmers]).to be_empty
      end

      it 'returns empty result for zero candidate_team_id' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: 0)
        expect(result[:confirmed]).to eq(0)
        expect(result[:swimmers]).to be_empty
      end
    end

    context 'when swimmer has target-season badge matching candidate team' do
      before(:each) do
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: target_season,
                                  team_affiliation: target_ta, category_type: category_type)
        FactoryBot.create(:badge, swimmer: swimmer2, team: team, season: target_season,
                                  team_affiliation: target_ta, category_type: category_type)
      end

      it 'confirms both swimmers and returns high confidence' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(2)
        expect(result[:total]).to eq(2)
        expect(result[:confidence]).to eq('high')
        expect(result[:confirmed_other_seasons]).to eq(0)
      end

      it 'includes matches_candidate true for each swimmer' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        result[:swimmers].each do |s|
          expect(s['matches_candidate']).to be true
        end
      end
    end

    context 'when swimmer has NO target-season badge but has other-season badge for candidate team' do
      before(:each) do
        # No target-season badge; only past-season badge for the same team
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: past_season,
                                  team_affiliation: past_ta, category_type: past_category_type)
        FactoryBot.create(:badge, swimmer: swimmer2, team: team, season: past_season,
                                  team_affiliation: past_ta, category_type: past_category_type)
      end

      it 'reports no target-season confirmation but other-season confirmation' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(0)
        expect(result[:confirmed_other_seasons]).to eq(2)
        expect(result[:total]).to eq(2)
      end

      it 'boosts confidence to high with other-season matches' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confidence]).to eq('high')
      end

      it 'includes other_season_badges with season_id for each swimmer' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        result[:swimmers].each do |s|
          expect(s['matches_candidate']).to be false
          expect(s['matches_candidate_other_seasons']).to be true
          expect(s['other_season_badges']).not_to be_empty
          expect(s['other_season_badges'].first['season_id']).to eq(past_season.id)
          expect(s['other_season_badges'].first['team_id']).to eq(team.id)
        end
      end

      it 'shows NO BADGE in badge_teams (empty) and other-season badges populated' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        result[:swimmers].each do |s|
          expect(s['badge_teams']).to be_empty
          expect(s['other_season_badges'].length).to be <= described_class::MAX_OTHER_SEASON_BADGES
        end
      end
    end

    context 'when swimmer has no badges at all' do
      it 'returns low confidence with no confirmations' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(0)
        expect(result[:confirmed_other_seasons]).to eq(0)
        expect(result[:confidence]).to eq('low')
      end

      it 'has empty badge_teams and empty other_season_badges' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        result[:swimmers].each do |s|
          expect(s['badge_teams']).to be_empty
          expect(s['other_season_badges']).to be_empty
          expect(s['matches_candidate']).to be false
          expect(s['matches_candidate_other_seasons']).to be false
        end
      end
    end

    context 'when other-season badges are for a different team' do
      before(:each) do
        other_ta = FactoryBot.create(:team_affiliation, team: other_team, season: past_season)
        FactoryBot.create(:badge, swimmer: swimmer, team: other_team, season: past_season,
                                  team_affiliation: other_ta, category_type: past_category_type)
        FactoryBot.create(:badge, swimmer: swimmer2, team: other_team, season: past_season,
                                  team_affiliation: other_ta, category_type: past_category_type)
      end

      it 'does not confirm other-seasons for candidate team' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(0)
        expect(result[:confirmed_other_seasons]).to eq(0)
        expect(result[:confidence]).to eq('low')
      end

      it 'still reports other_season_badges (any team)' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        result[:swimmers].each do |s|
          expect(s['other_season_badges']).not_to be_empty
          expect(s['matches_candidate_other_seasons']).to be false
        end
      end
    end

    context 'when other-season badges exceed MAX_OTHER_SEASON_BADGES' do
      let(:extra_season) { FactoryBot.create(:season, begin_date: Time.zone.today - 25.months, end_date: Time.zone.today - 16.months) }

      before(:each) do
        extra_cat = FactoryBot.create(:category_type, season: extra_season)
        extra_ta = FactoryBot.create(:team_affiliation, team: team, season: extra_season)
        older_ta = FactoryBot.create(:team_affiliation, team: team, season: past_season)

        # Create 4 badges across 2 past seasons — should be capped at 2 per swimmer
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: past_season,
                                  team_affiliation: older_ta, category_type: past_category_type)
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: extra_season,
                                  team_affiliation: extra_ta, category_type: extra_cat)
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: past_season,
                                  team_affiliation: older_ta, category_type: past_category_type)
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: extra_season,
                                  team_affiliation: extra_ta, category_type: extra_cat)
      end

      it 'limits other_season_badges to MAX_OTHER_SEASON_BADGES per swimmer' do
        # Only one swimmer in phase3_data for this context
        single_data = {
          'badges' => [{ 'team_key' => 'TK1', 'swimmer_id' => swimmer.id }],
          'swimmers' => [{ 'swimmer_id' => swimmer.id, 'complete_name' => 'Solo Swimmer' }]
        }
        checker = described_class.new(phase3_data: single_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        swimmer_result = result[:swimmers].first
        expect(swimmer_result['other_season_badges'].length).to eq(described_class::MAX_OTHER_SEASON_BADGES)
      end
    end

    context 'when no reference swimmers are found in phase3' do
      let(:empty_data) { { 'badges' => [], 'swimmers' => [] } }

      it 'returns empty result' do
        checker = described_class.new(phase3_data: empty_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(0)
        expect(result[:total]).to eq(0)
        expect(result[:swimmers]).to be_empty
        expect(result[:confidence]).to eq('none')
      end
    end

    context 'with mixed results: one target-season match, one other-season only' do
      before(:each) do
        # Swimmer 1: target-season badge for candidate team
        FactoryBot.create(:badge, swimmer: swimmer, team: team, season: target_season,
                                  team_affiliation: target_ta, category_type: category_type)
        # Swimmer 2: only past-season badge for candidate team
        FactoryBot.create(:badge, swimmer: swimmer2, team: team, season: past_season,
                                  team_affiliation: past_ta, category_type: past_category_type)
      end

      it 'confirms 1 target + 1 other-season = medium confidence' do
        checker = described_class.new(phase3_data: phase3_data, season_id: target_season.id)
        result = checker.check(team_key: 'TK1', candidate_team_id: team.id)

        expect(result[:confirmed]).to eq(1)
        expect(result[:confirmed_other_seasons]).to eq(1)
        expect(result[:total]).to eq(2)
        expect(result[:confidence]).to eq('medium')
      end
    end
  end
end
