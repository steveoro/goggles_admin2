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
            expect(city_name).to be_a(String) && be_present
            expect(area_code).to be_a(String) || be_nil
            expect(remainder).to be_a(String) && be_present
            # DEBUG
            # puts "city: '#{city_name}', #{remainder} (#{area_code})"
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
