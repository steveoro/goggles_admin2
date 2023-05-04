# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jsonifier, type: :strategy do
  describe 'self.call' do
    let(:fixture_asset_row) do
      [
        GogglesDb::User.all.sample, GogglesDb::Badge.first(100).sample, GogglesDb::Swimmer.first(50).sample,
        GogglesDb::Team.first(50).sample, GogglesDb::Meeting.first(50).sample, GogglesDb::SwimmingPool.first(50).sample
      ].sample
    end

    describe 'with invalid parameters,' do
      subject(:result) { described_class.call([nil, '', {}].sample) }

      it 'returns an empty hash as a JSON String' do
        expect(result).to eq('{}')
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    describe 'with valid parameters,' do
      subject(:result) { described_class.call(fixture_asset_row) }

      it 'returns a String' do
        expect(result).to be_a(String)
      end

      it 'is a valid JSON text' do
        expect { JSON.parse(result) }.not_to raise_error
      end

      it 'includes all attributes keys from the original asset row' do
        json = JSON.parse(result)
        expect(json.keys).to match_array(fixture_asset_row.attributes.keys)
      end

      it 'includes all attributes values from the original asset row with the DateTime converted to strings' do
        json = JSON.parse(result)
        special_columns = %i[date datetime]
        fixture_asset_row.attributes.each do |attr_name, attr_value|
          if attr_value.present? && special_columns.include?(fixture_asset_row.class.column_for_attribute(attr_name).type)
            expect(DateTime.parse(json[attr_name])).to eq(attr_value)
          else
            expect(json[attr_name]).to eq(attr_value)
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
