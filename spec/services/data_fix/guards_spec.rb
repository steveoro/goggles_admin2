# frozen_string_literal: true

require 'rails_helper'

# DataFix::Guards works whether or not Drift::Gate (08) and DbRestore::Lock (14) exist: fake classes here.
RSpec.describe DataFix::Guards do
  let(:gate_result) { Struct.new(:level, :reasons, :verdict) }
  # (plain doubles: the real Drift::Gate / DbRestore::Lock may not exist yet)
  let(:gate) { double('drift gate', check: gate_result.new(:ok, [], 'green')) } # rubocop:disable RSpec/VerifiedDoubles
  let(:idle_lock) { double('restore lock', active?: false) } # rubocop:disable RSpec/VerifiedDoubles

  it 'is :ok without any gate or lock (constants undefined)' do
    result = described_class.check(:commit, gate: nil, lock: nil)
    expect(result).to have_attributes(level: :ok, reasons: [])
    expect(result).to be_allowed
  end

  it 'passes scope, acknowledgement and force to the gate' do
    described_class.check(:prepare, acknowledged: true, force: true, gate:, lock: idle_lock)
    expect(gate).to have_received(:check).with(scope: :prepare, acknowledged: true, force: true)
  end

  it 'allows a warning only once acknowledged' do
    allow(gate).to receive(:check).and_return(gate_result.new(:warn, ['amber: laps'], 'amber'))
    expect(described_class.check(:commit, gate:, lock: idle_lock)).to have_attributes(level: :warn, allowed?: false, needs_acknowledgement?: true)
    expect(described_class.check(:commit, acknowledged: true, gate:, lock: idle_lock)).to be_allowed
  end

  it 'never allows a block, even acknowledged' do
    allow(gate).to receive(:check).and_return(gate_result.new(:block, ['red: remote ahead'], 'red'))
    result = described_class.check(:commit, acknowledged: true, gate:, lock: idle_lock)
    expect(result).to have_attributes(level: :block, allowed?: false, message: 'red: remote ahead')
  end

  it 'blocks while a DB restore is in progress, before asking the gate' do
    lock = double('restore lock', active?: true, current_run: nil) # rubocop:disable RSpec/VerifiedDoubles
    expect(described_class.check(:commit, gate:, lock:)).to have_attributes(level: :block, verdict: :restore)
    expect(gate).not_to have_received(:check)
  end

  it 'turns a failing gate into a warning (the operator can still acknowledge it)' do
    allow(gate).to receive(:check).and_raise(StandardError, 'boom')
    result = described_class.check(:commit, gate:, lock: idle_lock)
    expect(result).to have_attributes(level: :warn, verdict: :error)
    expect(result.reasons.first).to include('boom')
  end

  it 'rejects an unknown scope' do
    expect { described_class.check(:push, gate:, lock: idle_lock) }.to raise_error(ArgumentError)
  end
end
