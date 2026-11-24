# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::Setting do
  it 'requires a unique key' do
    FactoryBot.create(:ops_setting, key: 'spec.dup')
    duplicate = FactoryBot.build(:ops_setting, key: 'spec.dup')
    expect(duplicate).not_to be_valid
    expect(FactoryBot.build(:ops_setting, key: nil)).not_to be_valid
  end

  describe '.fetch' do
    it 'returns the default for a missing key' do
      expect(described_class.fetch('spec.missing')).to be_nil
      expect(described_class.fetch('spec.missing', 'x')).to eq('x')
    end

    it 'returns the stored JSON value' do
      FactoryBot.create(:ops_setting, key: 'spec.hash', value: { 'a' => [1, 2] })
      expect(described_class.fetch('spec.hash')).to eq('a' => [1, 2])
    end
  end

  describe '.store!' do
    it 'creates and then updates the same row' do
      expect { described_class.store!('spec.counter', 1) }.to change(described_class, :count).by(1)
      expect { described_class.store!(:'spec.counter', 2) }.not_to change(described_class, :count)
      expect(described_class.fetch('spec.counter')).to eq(2)
    end
  end

  describe '.db_epoch' do
    it 'is seeded to 1 by Ops::Database.prepare!' do
      expect(described_class.find_by(key: described_class::DB_EPOCH_KEY)).to be_present
      expect(described_class.db_epoch).to eq(1)
    end

    it 'returns the stored Integer' do
      described_class.store!(described_class::DB_EPOCH_KEY, 3)
      expect(described_class.db_epoch).to eq(3)
    end
  end
end
