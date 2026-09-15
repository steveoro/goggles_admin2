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
          }
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
