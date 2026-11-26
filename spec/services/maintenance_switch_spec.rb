# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance do
  describe '.enabled? / .store_enabled!' do
    it 'is on by default, stores the value and records an operations.switched event' do
      expect(described_class.enabled?).to be true

      expect(described_class.store_enabled!('0', user_id: 7)).to be false
      expect(described_class.enabled?).to be false
      event = Ops::Event.order(:id).last
      expect(event).to have_attributes(kind: 'operations.switched', level: 'warning', actor: 'operator',
                                       subject_type: 'setting', subject_key: 'operations.enabled', link_path: '/operations')
      expect(event.data).to eq('value' => false, 'user_id' => 7)

      expect(described_class.store_enabled!(true)).to be true
      expect(described_class.enabled?).to be true
      expect(Ops::Event.order(:id).last).to have_attributes(level: 'info')
    end

    it 'stores nothing without the ops DB (and the operations stay on)' do
      allow(Ops).to receive(:available?).and_return(false)
      expect(described_class.store_enabled!(false)).to be_nil
      expect(described_class.enabled?).to be true
    end

    it 'returns nil when the write fails' do
      allow(Ops::Setting).to receive(:store!).and_raise(ActiveRecord::StatementInvalid, 'locked')
      expect(described_class.store_enabled!(false)).to be_nil
    end
  end
end
