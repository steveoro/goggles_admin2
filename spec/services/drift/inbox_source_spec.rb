# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Drift::InboxSource do
  let(:api_url) { 'http://localhost:8081' }
  let(:context) { Inbox::Context.new(api_url:, now: Time.current) }

  after(:each) { Ops::Database.reset_state! }

  def items = described_class.new.items(context)

  it 'is registered in the :drift slot' do
    expect(described_class.key).to eq(:drift)
    expect(Inbox::Registry.sources[Inbox::Registry.keys.index(:drift)]).to eq(described_class)
  end

  it 'makes no item without a check, on green and on unknown' do
    expect(items).to eq([])
    FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 2.minutes.ago)
    expect(items).to eq([])
    FactoryBot.create(:ops_db_fingerprint, :unknown, api_base_url: api_url)
    expect(items).to eq([])
  end

  it "makes one 'blocked'-band item opening /db_sync on red" do
    FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: api_url)
    item = items.sole
    expect(item).to have_attributes(key: 'drift_red', band: :blocked, title: I18n.t('inbox.drift.red_title'))
    expect(item.detail).to include('laps')
    expect(item.action.path).to eq('/db_sync')
  end

  it "makes one 'notice' item on amber: the remote writes page when they are the only reason, else /db_sync" do
    FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
    expect(items.sole).to have_attributes(key: 'drift_amber', band: :notice)
    expect(items.sole.action.path).to eq('/remote_writes')

    FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 3.hours.ago) # (stale green: amber)
    Ops::DbFingerprint.where(verdict: 'amber').delete_all
    expect(items.sole.action.path).to eq('/db_sync')
  end

  it 'ignores the checks of another API' do
    FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: 'http://other:447')
    expect(items).to eq([])
  end
end
