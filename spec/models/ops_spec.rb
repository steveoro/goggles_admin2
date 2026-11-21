# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops do
  after(:each) { Ops::Database.reset_state! }

  it 'is available in the test environment (prepared by the suite boot)' do
    expect(described_class.state).to eq(:ready)
    expect(described_class).to be_available
  end

  it 'wraps the ops DB writes in the transactional fixtures' do
    expect(Ops::Event.connection.transaction_open?).to be true
  end

  describe '.safely' do
    it 'returns the block value' do
      expect(described_class.safely { 42 }).to eq(42)
    end

    it 'swallows & logs any StandardError, returning the default' do
      allow(Rails.logger).to receive(:warn)
      expect(described_class.safely(:fallback) { raise ArgumentError, 'boom' }).to eq(:fallback)
      expect(Rails.logger).to have_received(:warn).with(/\[Ops\] ArgumentError: boom/)
    end

    it 'retries once on ActiveRecord::StatementTimeout (busy DB)' do
      calls = 0
      result = described_class.safely do
        calls += 1
        raise ActiveRecord::StatementTimeout, 'database is locked' if calls == 1

        :done
      end
      expect(result).to eq(:done)
      expect(calls).to eq(2)
    end

    it 'gives up after the second ActiveRecord::StatementTimeout' do
      calls = 0
      result = described_class.safely([]) do
        calls += 1
        raise ActiveRecord::StatementTimeout, 'database is locked'
      end
      expect(result).to eq([])
      expect(calls).to eq(2)
    end
  end

  describe '.record_event!' do
    it 'appends an event row' do
      event = nil
      expect do
        event = described_class.record_event!(kind: 'datafix.committed', level: 'success', actor: 'operator', season_id: 242,
                                              subject_type: 'source', subject_key: 'a/b-lt4.json', data: { 'x' => 1 },
                                              link_path: '/x')
      end.to change(Ops::Event, :count).by(1)
      expect(event).to have_attributes(kind: 'datafix.committed', level: 'success', actor: 'operator', season_id: 242,
                                       subject_type: 'source', subject_key: 'a/b-lt4.json', data: { 'x' => 1 }, link_path: '/x')
      expect(event.occurred_at).to be_within(5.seconds).of(Time.current)
    end

    it 'uses the info/system defaults' do
      event = described_class.record_event!(kind: 'spec.defaults')
      expect(event).to have_attributes(level: 'info', actor: 'system', data: {})
    end

    it 'is a no-op returning nil when the ops DB is not available' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      allow(Ops::Event).to receive(:create!)
      expect(described_class.record_event!(kind: 'spec.unavailable')).to be_nil
      expect(Ops::Event).not_to have_received(:create!)
    end

    it 'returns nil (without raising) on an invalid event' do
      expect(described_class.record_event!(kind: 'spec.invalid', level: 'bogus')).to be_nil
    end

    it 'returns nil (without raising) when the write fails' do
      allow(Ops::Event).to receive(:create!).and_raise(ActiveRecord::StatementTimeout, 'database is locked')
      expect(described_class.record_event!(kind: 'spec.busy')).to be_nil
      expect(Ops::Event).to have_received(:create!).twice
    end
  end
end
