# frozen_string_literal: true

require 'rails_helper'
require 'securerandom'

RSpec.describe Import::Committers::SwimmingPool do
  let(:stats) do
    {
      pools_created: 0,
      pools_updated: 0,
      errors: []
    }
  end
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/test.log') }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats: stats, logger: logger, sql_log: sql_log) }

  let(:pool_attrs) do
    {
      'id' => nil,
      'name' => "Pool-#{SecureRandom.hex(4)}",
      'nick_name' => "zztest#{SecureRandom.hex(4)}",
      'address' => "Via #{SecureRandom.hex(3)}, 1",
      'pool_type_id' => GogglesDb::PoolType.first&.id,
      'lanes_number' => 8,
      'city_id' => GogglesDb::City.first&.id,
      'multiple_pools' => false,
      'garden' => false,
      'bar' => false,
      'restaurant' => false,
      'gym' => false,
      'child_area' => false,
      'read_only' => false
    }
  end

  describe '#commit' do
    context 'when two sessions reference the same new pool (duplicate submission)' do
      it 'commits the pool once and reuses the same row for the second session' do
        first_id = committer.commit(pool_attrs.deep_dup)
        second_id = committer.commit(pool_attrs.deep_dup)

        expect(first_id).to be_positive
        expect(second_id).to eq(first_id)
        expect(stats[:pools_created]).to eq(1)
        expect(stats[:pools_updated]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(GogglesDb::SwimmingPool.where(nick_name: pool_attrs['nick_name']).count).to eq(1)
        expect(sql_log.grep(/INSERT INTO `swimming_pools`|INSERT INTO swimming_pools/i).size).to eq(1)
      ensure
        GogglesDb::SwimmingPool.find_by(id: first_id)&.destroy
      end
    end

    context 'when the nick_name already exists in DB but the payload has a null id' do
      let!(:existing_pool) do
        FactoryBot.create(:swimming_pool, nick_name: "zzexisting#{SecureRandom.hex(3)}")
      end

      it 'reuses and updates the existing row instead of attempting a duplicate INSERT' do
        new_address = "Updated-#{SecureRandom.hex(3)}"
        update_hash = {
          'id' => nil,
          'nick_name' => existing_pool.nick_name,
          'name' => existing_pool.name,
          'address' => new_address
        }

        result = committer.commit(update_hash)

        expect(result).to eq(existing_pool.id)
        expect(stats[:pools_updated]).to eq(1)
        expect(stats[:pools_created]).to eq(0)
        expect(stats[:errors]).to be_empty
        expect(existing_pool.reload.address).to eq(new_address)
        expect(GogglesDb::SwimmingPool.where(nick_name: existing_pool.nick_name).count).to eq(1)
      ensure
        existing_pool.destroy
        existing_pool.city&.destroy
      end
    end

    context 'with valid attributes for a new record' do
      it 'creates a new SwimmingPool row and returns its ID' do
        new_id = committer.commit(pool_attrs)

        expect(new_id).to be_a(Integer)
        expect(new_id).to be_positive
        expect(stats[:pools_created]).to eq(1)
        expect(stats[:errors]).to be_empty

        created = GogglesDb::SwimmingPool.find(new_id)
        expect(created.name).to eq(pool_attrs['name'])
        expect(created.nick_name).to eq(pool_attrs['nick_name'])
      ensure
        GogglesDb::SwimmingPool.find_by(id: new_id)&.destroy
      end
    end

    context 'when creating a new pool with a blank nick_name' do
      it 'fails validation and records the error' do
        invalid_attrs = pool_attrs.merge('nick_name' => nil)

        expect { committer.commit(invalid_attrs) }.to raise_error(StandardError, /Invalid GogglesDb::SwimmingPool row/)
        expect(stats[:errors]).not_to be_empty
        expect(stats[:pools_created]).to eq(0)
      end
    end
  end

  describe '#prepare_model' do
    let!(:existing_pool) do
      FactoryBot.create(:swimming_pool, nick_name: "zzprep#{SecureRandom.hex(3)}")
    end

    it 'returns the existing row when only the nick_name matches' do
      model = committer.prepare_model('id' => nil, 'nick_name' => existing_pool.nick_name,
                                      'name' => existing_pool.name)

      expect(model).to be_persisted
      expect(model.id).to eq(existing_pool.id)
    ensure
      existing_pool.destroy
      existing_pool.city&.destroy
    end

    it 'builds an unsaved draft for a genuinely new pool' do
      model = committer.prepare_model(pool_attrs)

      expect(model).to be_new_record
      expect(model.nick_name).to eq(pool_attrs['nick_name'])
    end
  end
end
