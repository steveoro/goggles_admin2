# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::Blockers do
  include InboxSummaryFixtures

  before(:each) { allow(Ops::BackgroundCredentials).to receive(:status).and_return(:valid) }

  after(:each) { Ops::Database.reset_state! }

  def keys_for(**options)
    described_class.new.items(inbox_context(**options)).map(&:key)
  end

  it 'emits nothing when everything works' do
    expect(keys_for).to eq([])
  end

  it 'reports an API-offline session (Settings) and skips the credentials there' do
    allow(Ops::BackgroundCredentials).to receive(:status).and_return(:missing)
    item = described_class.new.items(inbox_context(api_offline: true)).first
    expect(item).to have_attributes(key: 'blocker:api_offline', band: :blocked)
    expect(item.action.path).to eq('/settings')
    expect(keys_for(api_offline: true)).to eq(['blocker:api_offline'])
  end

  it 'asks to sign in again with expired or missing background credentials' do
    allow(Ops::BackgroundCredentials).to receive(:status).and_return(:expired)
    item = described_class.new.items(inbox_context).first
    expect(item.action).to have_attributes(http_method: :delete, path: '/users/sign_out')
    expect(item.detail).to eq(I18n.t('inbox.blockers.credentials.expired'))
  end

  it 'reports the ops DB not ready and a dead job queue, with the docs' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    dead = SystemStatus::Result.new(key: :queue, label: 'Jobs', level: :error, detail: 'No live supervisor')
    allow(SystemStatus::QueueProbe).to receive(:new).and_return(instance_double(SystemStatus::QueueProbe, call: dead))
    items = described_class.new.items(inbox_context(ops_available: false)).index_by(&:key)
    expect(items.keys).to contain_exactly('blocker:ops_db', 'blocker:queue')
    expect(items['blocker:ops_db'].detail).to include('ops:prepare')
    expect(items['blocker:queue'].detail).to eq('No live supervisor')
    expect(items.values.map { |item| item.action.external? }).to all(be true)
  end
end
