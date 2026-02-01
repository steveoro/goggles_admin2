# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe CityName, type: :strategy do
    describe 'self.tokenize_address' do
      let(:addresses) { YAML.load_file(Rails.root.join('spec/fixtures/parser/addresses-202.yml')) }

      describe 'with valid parameters,' do
        it 'returns an array having the city name and the province code with the remainder of the address, if any' do
          addresses.each do |address|
            city_name, area_code, remainder = described_class.tokenize_address(address)
            expect(city_name).to be_a(String)
            expect(city_name).not_to be_empty
            expect(area_code).to be_nil.or be_a(String)
            # The remainder won't ever be nil but it may be an empty string:
            expect(remainder).to be_empty.or be_a(String)
          end
        end
      end

      context 'when dealing with edge and error cases' do
        it 'handles address with only city name' do
          expect(described_class.tokenize_address('Rome')).to eq(['Rome', nil, ''])
        end

        it 'handles city name with round brackets area code' do
          expect(described_class.tokenize_address('Rome (RM)')).to eq(['Rome', 'RM', ''])
        end

        it 'handles city name with square brackets area code' do
          expect(described_class.tokenize_address('Rome [RM]')).to eq(['Rome', 'RM', ''])
        end

        it 'handles address with city at end and area code' do
          expect(described_class.tokenize_address('Via Something - Rome (RM)')).to eq(['Rome', 'RM', 'Via Something'])
        end

        it 'handles address with city at start and area code' do
          expect(described_class.tokenize_address('Rome (RM) - Via Something')).to eq(['Rome', 'RM', 'Via Something'])
        end

        it 'handles address with semicolon delimiter' do
          expect(described_class.tokenize_address('Via Something; Rome (RM)')).to eq(['Rome', 'RM', 'Via Something'])
        end

        it 'handles nil input' do
          expect(described_class.tokenize_address(nil)).to eq([nil, nil, ''])
        end

        it 'handles empty string input' do
          expect(described_class.tokenize_address('')).to eq([nil, nil, ''])
        end

        it 'handles malformed area code' do
          expect(described_class.tokenize_address('Rome RM)')).to eq(['Rome RM)', nil, ''])
        end

        it 'handles unicode and special characters' do
          expect(described_class.tokenize_address('München (BY)')).to eq(['München', 'BY', ''])
        end

        it 'handles address with extra delimiters' do
          expect(described_class.tokenize_address('Via; Something - Rome (RM)')).to eq(['Rome', 'RM', 'Via; Something'])
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
