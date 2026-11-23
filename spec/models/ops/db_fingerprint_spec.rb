# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::DbFingerprint do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_url) { 'http://localhost:8081' }

  it 'is valid with the factory defaults and validates verdict, trigger and mode' do
    expect(FactoryBot.build(:ops_db_fingerprint)).to be_valid
    expect(FactoryBot.build(:ops_db_fingerprint, verdict: 'pink')).not_to be_valid
    expect(FactoryBot.build(:ops_db_fingerprint, trigger: 'cron')).not_to be_valid
    expect(FactoryBot.build(:ops_db_fingerprint, mode: 'heavy')).not_to be_valid
    expect(FactoryBot.build(:ops_db_fingerprint, taken_at: nil)).not_to be_valid
  end

  it 'finds the latest check (and the latest full one) per API URL, trailing slash ignored' do
    full = FactoryBot.create(:ops_db_fingerprint, taken_at: 20.minutes.ago)
    light = FactoryBot.create(:ops_db_fingerprint, mode: 'light', taken_at: 5.minutes.ago)
    FactoryBot.create(:ops_db_fingerprint, api_base_url: 'http://other:447')
    expect(described_class.latest("#{api_url}/")).to eq(light)
    expect(described_class.latest_full(api_url)).to eq(full)
    expect(described_class.last_green_at(api_url)).to be_within(1.second).of(light.taken_at)
  end

  it 'reads a green check older than 2 hours as amber (stale), and maps verdicts to status levels' do
    row = FactoryBot.create(:ops_db_fingerprint, taken_at: 3.hours.ago)
    expect(row.effective_verdict).to eq('amber')
    expect(row.level).to eq(:warn)
    expect(row.reason_list.first).to include(code: 'stale')
    expect(FactoryBot.create(:ops_db_fingerprint, :red, taken_at: 3.hours.ago).level).to eq(:error)
    expect(FactoryBot.create(:ops_db_fingerprint).level).to eq(:ok)
    expect(FactoryBot.create(:ops_db_fingerprint, :unknown).level).to eq(:unknown)
  end

  it 'lists the per-table comparison rows in whitelist order' do
    row = FactoryBot.build(:ops_db_fingerprint,
                           local: { 'tables' => { 'meetings' => { 'max_id' => 5 }, 'laps' => { 'max_id' => 9 } } },
                           remote: { 'tables' => { 'laps' => { 'max_id' => 10 } } })
    expect(row.table_rows).to eq([{ table: 'meetings', local: { 'max_id' => 5 }, remote: {} },
                                  { table: 'laps', local: { 'max_id' => 9 }, remote: { 'max_id' => 10 } }])
  end

  it 'prunes all but the last rows' do
    3.times { |i| FactoryBot.create(:ops_db_fingerprint, taken_at: i.hours.ago) }
    newest = described_class.recent.first
    expect(described_class.prune!(keep: 1)).to eq(2)
    expect(described_class.all).to eq([newest])
  end
end
