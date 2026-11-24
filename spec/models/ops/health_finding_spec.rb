# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::HealthFinding do
  it 'validates the group, the severity and the status' do
    expect(FactoryBot.build(:ops_health_finding)).to be_valid
    expect(FactoryBot.build(:ops_health_finding, severity: 'fatal')).not_to be_valid
    expect(FactoryBot.build(:ops_health_finding, status: 'done')).not_to be_valid
    expect(FactoryBot.build(:ops_health_finding, group_key: 'other')).not_to be_valid
  end

  it 'hashes the check key, the season and the entity ids into the fingerprint, and the payload in any key order' do
    one = described_class.fingerprint_for(check_key: 'badges.relay_category', season_id: 242, identity: 'badge:45')
    expect(one).to eq(Digest::SHA256.hexdigest('badges.relay_category|242|badge:45'))
    expect(described_class.digest_for('b' => 1, 'a' => { 'y' => 2, 'x' => 3 })).to eq(described_class.digest_for('a' => { 'x' => 3, 'y' => 2 }, 'b' => 1))
  end

  it 'shows its title in the current locale, falling back to the stored one when the text takes other arguments' do
    finding = FactoryBot.build(:ops_health_finding, check_key: 'season.setup', title: 'stored title',
                                                    payload: { 'title_args' => { 'id' => 7, 'categories' => 0, 'timings' => 1 } })
    expect(finding.display_title).to eq(I18n.t('health.checks.season.setup.finding', id: 7, categories: 0, timings: 1))
    finding.payload = { 'title_args' => { 'id' => 7 } }
    expect(finding.display_title).to eq('stored title')
  end

  it 'prunes the resolved findings older than the retention' do
    old = FactoryBot.create(:ops_health_finding, status: 'resolved', resolved_at: 200.days.ago)
    kept = FactoryBot.create(:ops_health_finding, status: 'resolved', resolved_at: 1.day.ago)
    expect(described_class.prune_resolved!).to eq(1)
    expect(described_class.where(id: [old.id, kept.id]).pluck(:id)).to eq([kept.id])
  end
end
