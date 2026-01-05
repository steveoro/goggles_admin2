# frozen_string_literal: true

require 'rails_helper'
require 'securerandom'

RSpec.describe Import::Committers::City do
  let(:stats) do
    {
      cities_created: 0,
      cities_updated: 0,
      errors: []
    }
  end
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/test.log') }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats: stats, logger: logger, sql_log: sql_log) }

  describe '#commit' do
    context 'with valid attributes from the factory (new record)' do
      let(:city_attrs) do
        FactoryBot.build(
          :city,
          name: "City-#{SecureRandom.hex(4)}",
          area: "Area-#{SecureRandom.hex(4)}",
          country_code: 'IT',
          country: 'Italia'
        ).attributes
      end

      it 'creates a new City row and returns its ID' do
        new_id = committer.commit(city_attrs)

        expect(new_id).to be_a(Integer)
        expect(new_id).to be_positive
        expect(stats[:cities_created]).to eq(1)
        expect(stats[:errors]).to be_empty

        created = GogglesDb::City.find(new_id)
        expect(created.name).to eq(city_attrs['name'])
        expect(created.area).to eq(city_attrs['area'])
      ensure
        GogglesDb::City.find_by(id: new_id)&.destroy
      end
    end

    context 'when attributes contain only an id and nil values' do
      let!(:existing_city) { GogglesDb::City.first }
      let(:nil_attrs) do
        {
          'id' => existing_city.id,
          'name' => nil,
          'area' => nil,
          'country' => nil,
          'country_code' => nil
        }
      end

      it 'ignores nil values and does not mark attributes as changed' do
        original_attrs = existing_city.attributes.slice('name', 'area', 'country', 'country_code')

        result = committer.commit(nil_attrs)

        expect(result).to eq(existing_city.id)
        expect(stats[:cities_updated]).to eq(0)
        expect(stats[:cities_created]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(sql_log).to be_empty
        expect(existing_city.reload.attributes.slice('name', 'area', 'country', 'country_code')).to eq(original_attrs)
      end
    end

    context 'when updating an existing city with meaningful changes' do
      let!(:city) do
        GogglesDb::City.create!(
          name: "City-#{SecureRandom.hex(4)}",
          area: "Area-#{SecureRandom.hex(4)}",
          country_code: 'IT',
          country: 'Italia'
        )
      end

      it 'updates the City row and tracks the update' do
        new_area = "Area-#{SecureRandom.hex(4)}"
        update_attrs = {
          'id' => city.id,
          'name' => city.name,
          'area' => new_area,
          'country_code' => city.country_code,
          'country' => city.country
        }

        result = committer.commit(update_attrs)

        expect(result).to eq(city.id)
        expect(stats[:cities_updated]).to eq(1)
        expect(stats[:cities_created]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(sql_log).not_to be_empty
        expect(city.reload.area).to eq(new_area)
      ensure
        city.destroy
      end
    end

    context 'when creating a new city without explicit country fields' do
      let(:minimal_attrs) do
        {
          'name' => "City-#{SecureRandom.hex(4)}",
          'area' => "Area-#{SecureRandom.hex(4)}"
        }
      end

      it 'applies default country and country_code values' do
        new_id = committer.commit(minimal_attrs)

        created = GogglesDb::City.find(new_id)
        expect(created.country_code).to eq('IT')
        expect(created.country).to eq('Italia')
        expect(stats[:cities_created]).to eq(1)
        expect(stats[:errors]).to be_empty
      ensure
        GogglesDb::City.find_by(id: new_id)&.destroy
      end
    end
  end
end
