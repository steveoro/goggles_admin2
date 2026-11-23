# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::Drift do
  include InboxSummaryFixtures

  let(:api_url) { 'http://localhost:8081' }

  it 'is disabled without the ops DB' do
    expect(described_class.enabled?(inbox_context(ops_available: false))).to be false
  end

  it 'emits nothing while drift v0 is ok or unknown' do
    Ops::Snapshot.write!("drift_v0:#{api_url}", { 'status' => 'ok', 'missing' => {} })
    expect(described_class.new.items(inbox_context)).to eq([])
  end

  it 'emits one notice for the remote writes page on a warning' do
    FactoryBot.create(:ops_remote_write, base_url: api_url)
    item = described_class.new.items(inbox_context).first
    expect(item).to have_attributes(key: 'drift_v0', band: :notice)
    expect(item.detail).to eq(I18n.t('shell.status.drift_v0.remote_writes', count: 1))
    expect(item.action.path).to eq('/remote_writes')
  end
end
