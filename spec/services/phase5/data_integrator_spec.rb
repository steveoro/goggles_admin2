# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Phase5::DataIntegrator, type: :service do
  let(:season) { FactoryBot.create(:season) }

  let(:source_data) { { 'dates' => '2023-01-29' } }
  let(:phase3_data) do
    {
      'data' => {
        'swimmers' => [
          {
            'key' => 'F|PARALUPPI|ANNA|2002|CLOROMANIA SSD - MANTOVA',
            'gender_type_code' => 'F',
            'category_type_code' => 'U25'
          },
          { 'key' => 'M|ROSSI|MARIO|1970|Team A', 'gender_type_code' => 'M', 'category_type_code' => 'M50' },
          { 'key' => '|ROSSI|MARIO|1970|Team B', 'gender_type_code' => 'F', 'category_type_code' => 'M45' }
        ]
      }
    }
  end
  let(:integrator) do
    described_class.new(
      source_data: source_data,
      phase3_data: phase3_data,
      season: season,
      categories_cache: PdfResults::CategoriesCache.new(season)
    )
  end

  before(:each) do
    # Individual categories: U25 (under 25) + M25..M30 brackets
    FactoryBot.create(:category_type, season: season, code: 'U25', age_begin: 16, age_end: 24)
    FactoryBot.create(:category_type, season: season, code: 'M25', age_begin: 25, age_end: 29)
    FactoryBot.create(:category_type, season: season, code: 'M30', age_begin: 30, age_end: 34)
    # Relay categories: catch-all + a real age-sum range
    FactoryBot.create(:category_type, season: season, code: '000-999', age_begin: 1, age_end: 999, relay: true, undivided: true)
    FactoryBot.create(:category_type, season: season, code: '100-119', age_begin: 100, age_end: 119, relay: true)
  end

  describe '#integrate_individual_result' do
    let(:event) { { 'eventCode' => '50SL', 'eventGender' => 'F', 'relay' => false } }

    it 'keeps a source category that exists for the season' do
      result = { 'category' => 'M25', 'gender' => 'F', 'swimmer' => 'F|PARALUPPI|ANNA|2002|TEAM X' }
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('M25')
    end

    it 'resolves an invalid source category through the Phase-3 swimmer category' do
      result = { 'category' => 'A20', 'gender' => 'F',
                 'swimmer' => 'F|PARALUPPI|ANNA|2002|CLOROMANIA SSD - MANTOVA' }
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('U25')
    end

    it 'resolves a non-DB source code (e.g., FICR "UNF") through Phase 3' do
      result = { 'category' => 'UNF', 'gender' => 'F',
                 'swimmer' => 'F|PARALUPPI|ANNA|2002|CLOROMANIA SSD - MANTOVA' }
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('U25')
    end

    it 'disambiguates same-named swimmers of different teams through the team token' do
      result = { 'category' => 'A20', 'swimmer' => 'ROSSI|MARIO|1970|Team B' }
      integrated = integrator.integrate_individual_result(result: result, event: event)
      expect(integrated[:category]).to eq('M45')
      expect(integrated[:gender]).to eq('F')
    end

    it 'uses the Phase-3 category also when the source category is missing' do
      result = { 'gender' => 'F', 'swimmer' => 'F|PARALUPPI|ANNA|2002|CLOROMANIA SSD - MANTOVA' }
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('U25')
    end

    it 'falls back to YOB computation when the swimmer is not in Phase 3' do
      result = { 'category' => 'A20', 'gender' => 'M', 'swimmer' => 'M|ROSSI|MARIO|1997|TEAM Y' }
      # age at 2023-01-29 = 26 -> M25
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('M25')
    end

    it 'keeps the raw source value when nothing can resolve it' do
      result = { 'category' => 'BOGUS', 'gender' => 'M', 'swimmer' => 'M||0|TEAM Y' }
      expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('BOGUS')
    end

    context 'without a season (no categories cache)' do
      let(:integrator) { described_class.new(source_data: source_data, phase3_data: phase3_data, season: nil) }

      it 'passes the source category through unchanged' do
        result = { 'category' => 'A20', 'gender' => 'F', 'swimmer' => 'F|PARALUPPI|ANNA|2002|TEAM' }
        expect(integrator.integrate_individual_result(result: result, event: event)[:category]).to eq('A20')
      end
    end
  end

  describe '#find_swimmer_in_phase3' do
    let(:anna) { phase3_data['data']['swimmers'].first }

    it 'matches the exact phase-3 key' do
      expect(integrator.send(:find_swimmer_in_phase3, anna['key'])).to eq(anna)
    end

    it 'matches a partial key without gender prefix and team token' do
      expect(integrator.send(:find_swimmer_in_phase3, 'PARALUPPI|ANNA|2002')).to eq(anna)
      expect(integrator.send(:find_swimmer_in_phase3, '|PARALUPPI|ANNA|2002')).to eq(anna)
    end

    it 'matches a partial key carrying a different gender prefix' do
      expect(integrator.send(:find_swimmer_in_phase3, 'M|PARALUPPI|ANNA|2002')).to eq(anna)
    end

    it 'prefers the most complete match when two swimmers share name and YOB' do
      team_a, team_b = phase3_data['data']['swimmers'].last(2)
      expect(integrator.send(:find_swimmer_in_phase3, 'ROSSI|MARIO|1970|Team B')).to eq(team_b)
      expect(integrator.send(:find_swimmer_in_phase3, 'F|ROSSI|MARIO|1970|Team A')).to eq(team_a)
      expect(integrator.send(:find_swimmer_in_phase3, '|ROSSI|MARIO|1970|Team A')).to eq(team_a)
    end

    it 'falls back to the first name/YOB match when the team is missing or unknown' do
      team_a = phase3_data['data']['swimmers'][1]
      expect(integrator.send(:find_swimmer_in_phase3, 'ROSSI|MARIO|1970')).to eq(team_a)
      expect(integrator.send(:find_swimmer_in_phase3, 'ROSSI|MARIO|1970|Team C')).to eq(team_a)
    end

    it 'does not strip a last name starting with M or F as if it were a gender prefix' do
      expect(integrator.send(:find_swimmer_in_phase3, 'MARIO|ROSSI|1970')).to be_nil
    end

    it 'returns nil for unknown or blank keys' do
      expect(integrator.send(:find_swimmer_in_phase3, 'BIANCHI|LUCA|1980')).to be_nil
      expect(integrator.send(:find_swimmer_in_phase3, '')).to be_nil
    end

    it 'builds the swimmer indexes only once' do
      swimmers = phase3_data['data']['swimmers']
      allow(swimmers).to receive(:each_with_object).and_call_original
      3.times { integrator.send(:find_swimmer_in_phase3, 'PARALUPPI|ANNA|2002') }
      expect(swimmers).to have_received(:each_with_object).twice
    end
  end

  describe '#integrate_relay_result' do
    let(:event) { { 'eventCode' => 'S4X50SL', 'eventGender' => 'M', 'relay' => true } }

    it 'keeps a valid relay age-range category' do
      result = { 'category' => '100-119', 'gender' => 'M', 'team' => 'TEAM X' }
      expect(integrator.integrate_relay_result(result: result, event: event)[:category]).to eq('100-119')
    end

    it 'maps the "*" summary token to the undivided relay category' do
      result = { 'category' => '*', 'gender' => 'M', 'team' => 'TEAM X' }
      expect(integrator.integrate_relay_result(result: result, event: event)[:category]).to eq('000-999')
    end

    it 'computes the category from swimmer ages when resolvable' do
      result = {
        'category' => '*', 'gender' => 'M', 'team' => 'TEAM X',
        'laps' => [
          { 'swimmer' => 'M|ROSSI|MARIO|1970|TEAM X' },
          { 'swimmer' => 'M|BIANCHI|LUCA|1970|TEAM X' },
          { 'swimmer' => 'M|VERDI|PAOLO|1970|TEAM X' },
          { 'swimmer' => 'M|NERI|GIANNI|1970|TEAM X' }
        ]
      }
      # 4 x ~53y at 2023-01-29 -> sum 212 -> "M212" (committer re-resolves to an age range)
      expect(integrator.integrate_relay_result(result: result, event: event)[:category]).to eq('M212')
    end
  end
end
