# frozen_string_literal: true

require 'rails_helper'

# The MySQL pool disconnect is stubbed: the pinned test connection must survive.
RSpec.describe DbRestore::Reconnect do
  let(:pool) { ActiveRecord::Base.connection_pool }

  before(:each) { allow(pool).to receive(:disconnect!) }

  it 'only records the epoch on the first look of a pool' do
    expect(described_class.check!(5)).to be(false)
    expect(pool).not_to have_received(:disconnect!)
    expect(described_class.check!(5)).to be(false)
  end

  it 'disconnects once when the epoch changed' do
    described_class.check!(5)
    expect(described_class.check!(6)).to be(true)
    expect(described_class.check!(6)).to be(false)
    expect(pool).to have_received(:disconnect!).once
  end

  it 'retries on the next call when the disconnect failed (the new epoch is recorded only after a success)' do
    described_class.check!(5)
    calls = 0
    allow(pool).to receive(:disconnect!) do
      calls += 1
      raise ActiveRecord::ExclusiveConnectionTimeoutError, 'busy' if calls == 1
    end
    expect(described_class.check!(6)).to be(false)
    expect(described_class.check!(6)).to be(true)
    expect(calls).to eq(2)
    expect(described_class.check!(6)).to be(false)
  end
end
