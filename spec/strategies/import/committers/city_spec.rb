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

    context 'when two sessions reference the same new city (duplicate submission)' do
      let(:twin_city_attrs) do
        {
          'id' => nil,
          'name' => "City-#{SecureRandom.hex(4)}",
          'area' => "Area-#{SecureRandom.hex(4)}",
          'country_code' => 'IT',
          'country' => 'Italia'
        }
      end

      it 'commits the city once and reuses the same row for the second session' do
        first_id = committer.commit(twin_city_attrs.deep_dup)
        second_id = committer.commit(twin_city_attrs.deep_dup)

        expect(first_id).to be_positive
        expect(second_id).to eq(first_id)
        expect(stats[:cities_created]).to eq(1)
        expect(stats[:cities_updated]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(
          GogglesDb::City.where(country_code: 'IT', area: twin_city_attrs['area'],
                                name: twin_city_attrs['name']).count
        ).to eq(1)
      ensure
        GogglesDb::City.find_by(id: first_id)&.destroy
      end
    end

    context 'when the (country_code, area, name) tuple already exists in DB but the payload has a null id' do
      let!(:existing_city) { FactoryBot.create(:city) }

      it 'reuses and updates the existing row instead of attempting a duplicate INSERT' do
        new_zip = '00123'
        update_hash = {
          'id' => nil,
          'name' => existing_city.name,
          'area' => existing_city.area,
          'country_code' => existing_city.country_code,
          'country' => existing_city.country,
          'zip' => new_zip
        }

        result = committer.commit(update_hash)

        expect(result).to eq(existing_city.id)
        expect(stats[:cities_updated]).to eq(1)
        expect(stats[:cities_created]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(existing_city.reload.zip).to eq(new_zip)
      ensure
        existing_city.destroy
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
