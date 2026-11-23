# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Drift::V0Status do
  let(:api_url) { 'http://localhost:8081' }
  let(:ok_payload) { { 'status' => 'ok', 'missing' => {}, 'missing_count' => 0 } }

  def status_for(payload:, remote_writes: 0, checked_at: Time.current)
    described_class.new(base_url: api_url, payload:, checked_at:, remote_writes:)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'is :ok with a fresh ok check and no remote writes' do
    expect(status_for(payload: ok_payload)).to have_attributes(level: :ok, reasons: [:ok])
  end

  it 'is :warn for remote writes even without a check or after a failed one' do
    expect(status_for(payload: nil, checked_at: nil, remote_writes: 2)).to have_attributes(level: :warn, reasons: [:remote_writes])
    expect(status_for(payload: ok_payload.merge('status' => 'unreachable'), remote_writes: 1).level).to eq(:warn)
  end

  it 'lists both reasons, missing rows first, with their translated details' do
    status = status_for(payload: ok_payload.merge('missing' => { 'teams' => [5, 6] }), remote_writes: 3)
    expect(status).to have_attributes(level: :warn, reasons: %i[missing remote_writes], missing_count: 2)
    expect(status.details).to eq([I18n.t('shell.status.drift_v0.missing', count: 2, tables: 'teams: 2'),
                                  I18n.t('shell.status.drift_v0.remote_writes', count: 3)])
  end

  it 'ignores the missing rows of a stale check' do
    status = status_for(payload: ok_payload.merge('missing' => { 'teams' => [5] }), checked_at: 2.hours.ago)
    expect(status).to have_attributes(level: :unknown, reasons: [:stale])
  end

  it 'maps an unexpected check status to :error' do
    expect(status_for(payload: ok_payload.merge('status' => 'weird')).reasons).to eq([:error])
  end

  it 'is :unknown with the ops DB not available' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.for(api_url)).to have_attributes(level: :unknown, reasons: [:ops_unavailable])
  end
end
