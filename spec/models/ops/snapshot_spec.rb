# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::Snapshot do
  include ActiveSupport::Testing::TimeHelpers

  it 'is valid with the factory defaults' do
    expect(FactoryBot.build(:ops_snapshot)).to be_valid
  end

  it 'requires a unique key and a payload' do
    FactoryBot.create(:ops_snapshot, key: 'spec.dup')
    expect(FactoryBot.build(:ops_snapshot, key: 'spec.dup')).not_to be_valid
    expect(FactoryBot.build(:ops_snapshot, payload: nil)).not_to be_valid
    expect(FactoryBot.build(:ops_snapshot, payload: {})).to be_valid
  end

  describe '.write!' do
    it 'upserts on the key, refreshing payload, source & taken_at' do
      first = travel_to(2.hours.ago) { described_class.write!('api.status:http://x', { 'ok' => false }, source: 'probe') }
      second = nil
      expect { second = described_class.write!('api.status:http://x', { 'ok' => true }) }.not_to change(described_class, :count)
      expect(second.id).to eq(first.id)
      expect(second.reload).to have_attributes(payload: { 'ok' => true }, source: nil)
      expect(second.taken_at).to be > first.taken_at
    end
  end

  describe '.read' do
    it 'returns the record or nil' do
      described_class.write!('kpi:http://x', [1, 2], source: 'spec')
      expect(described_class.read('kpi:http://x')).to have_attributes(payload: [1, 2], source: 'spec')
      expect(described_class.read('kpi:missing')).to be_nil
    end
  end
end
