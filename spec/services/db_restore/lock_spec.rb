# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::Lock do
  after(:each) { Ops::Database.reset_state! }

  it 'is inactive without a holder' do
    expect(described_class.active?).to be(false)
    expect(described_class.current_run).to be_nil
  end

  it 'is held by a locking run from acquire! to release!' do
    run = create_restore_run(status: 'confirmed')
    expect(described_class.acquire!(run)).to be(true)
    expect(described_class.active?).to be(true)
    expect(described_class.current_run).to eq(run)
    expect(described_class.since).to be_within(5.seconds).of(Time.current)
    expect(described_class.release!(run)).to be(true)
    expect(described_class.active?).to be(false)
  end

  it 'stays active through an interrupted load' do
    run = lock_with_run(status: 'loading')
    run.update!(status: 'interrupted')
    expect(described_class.current_run).to eq(run)
  end

  it 'counts as released when the holder is no longer locking' do
    run = lock_with_run(status: 'loading')
    run.update!(status: 'finished')
    expect(described_class.active?).to be(false)
    other = create_restore_run(status: 'confirmed')
    expect(described_class.acquire!(other)).to be(true)
    expect(described_class.current_run).to eq(other)
  end

  it 'is idempotent for the same run and refuses another one' do
    run = lock_with_run(status: 'confirmed')
    expect(described_class.acquire!(run)).to be(true)
    other = create_restore_run(status: 'confirmed')
    expect { described_class.acquire!(other) }.to raise_error(described_class::HeldError)
    expect(described_class.release!(other)).to be(false)
    expect(described_class.current_run).to eq(run)
  end

  it 'is inactive (never raises) without the ops DB' do
    lock_with_run
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.active?).to be(false)
    expect(described_class.current_run).to be_nil
  end
end
