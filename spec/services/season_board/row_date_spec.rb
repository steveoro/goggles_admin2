# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::RowDate do
  describe '.parse' do
    [
      ['24/10', '2026', '2026-10-24', '2026-10-24'],
      ['08/11', '2026', '2026-11-08', '2026-11-08'],
      ['21-22/11', '2026', '2026-11-21', '2026-11-22'],
      ['06-08/12', '2026', '2026-12-06', '2026-12-08'],
      ['31/10-8_11', '2026', '2026-10-31', '2026-11-08'],
      ['31/10-08/11', '2026', '2026-10-31', '2026-11-08'],
      ['30/12-02/01', '2026', '2026-12-30', '2027-01-02'],
      ['31-02/01', '2027', '2026-12-31', '2027-01-02'],
      ['30-02/11', '2026', '2026-10-30', '2026-11-02'],
      [' 06 - 14/02 ', '2027', '2027-02-06', '2027-02-14'],
      ['9/1', 2027, '2027-01-09', '2027-01-09']
    ].each do |text, year, first, last|
      it "parses #{text.inspect} (#{year}) as #{first}..#{last}" do
        row_date = described_class.parse(text, year)
        expect(row_date).to be_valid
        expect(row_date.first_date).to eq(Date.parse(first))
        expect(row_date.last_date).to eq(Date.parse(last))
        expect(row_date.text).to eq(text)
      end
    end

    ['', nil, 'TBD', '32/10', '10/13', '24/10-'].each do |text|
      it "returns an invalid (nil dates) instance for #{text.inspect}" do
        row_date = described_class.parse(text, '2026')
        expect(row_date).not_to be_valid
        expect(row_date.first_date).to be_nil
        expect(row_date.last_date).to be_nil
      end
    end

    it 'is invalid without a year' do
      expect(described_class.parse('24/10', nil)).not_to be_valid
      expect(described_class.parse('24/10', 'abc')).not_to be_valid
    end
  end

  describe '#past?' do
    subject(:row_date) { described_class.parse('21-22/11', '2026') }

    it 'is true only once the last date is before today' do
      expect(row_date.past?(Date.new(2026, 11, 21))).to be false
      expect(row_date.past?(Date.new(2026, 11, 22))).to be false
      expect(row_date.past?(Date.new(2026, 11, 23))).to be true
    end

    it 'is false for an unparsable date' do
      expect(described_class.parse('TBD', '2026').past?(Date.new(2030, 1, 1))).to be false
    end
  end
end
