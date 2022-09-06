# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe SessionDate, type: :strategy do
    describe 'self.from_l2_result' do
      let(:fixture_day) { (1..30).to_a.sample }
      let(:fixture_year) { (rand * 20).to_i + 2000 }
      let(:fixture_month) { %w[Gennaio Febbraio Marzo Aprile Maggio Giugno Luglio Agosto Settembre Ottobre Novembre Dicembre].sample }

      describe 'with valid parameters,' do
        it 'returns a valid ISO-formatted string date' do
          result = described_class.from_l2_result(fixture_day, fixture_month, fixture_year)
          expect(result).to be_a(String) && match(/#{fixture_year}-\d{2}-0?#{fixture_day}/)
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
