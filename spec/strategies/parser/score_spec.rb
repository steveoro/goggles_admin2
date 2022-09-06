# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe Score, type: :strategy do
    describe 'self.from_l2_result' do
      let(:fixtures) do
        [
          ['792,98', 792.98],
          ['578,12', 578.12],
          ['929,35', 929.35],
          ['1015,45', 1015.45],
          ['1\'052,23', 1052.23],
          ['123\'456\'052,78', 123456052.78],
          ['1\'001,234', 1001.234],
          ['998,5', 998.5]
        ]
      end

      describe 'with valid parameters,' do
        it 'returns both the corresponding EventType and CategoryType rows for the specified text' do
          fixtures.each do |text, expected|
            # DEBUG
            # puts "Parsing \"#{text}\" => #{expected}"
            value = described_class.from_l2_result(text)
            expect(value).to eq(expected)
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
