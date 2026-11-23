# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::HealthRun do
  it 'validates the group, the trigger and the status' do
    expect(FactoryBot.build(:ops_health_run)).to be_valid
    expect(FactoryBot.build(:ops_health_run, group_key: 'other')).not_to be_valid
    expect(FactoryBot.build(:ops_health_run, trigger: 'cron')).not_to be_valid
    expect(FactoryBot.build(:ops_health_run, status: 'done')).not_to be_valid
  end

  it 'returns the latest finished run per season and group, and the last succeeded one' do
    FactoryBot.create(:ops_health_run, season_id: 1, group_key: 'badges', status: 'succeeded')
    failed = FactoryBot.create(:ops_health_run, season_id: 1, group_key: 'badges', status: 'failed')
    FactoryBot.create(:ops_health_run, season_id: 1, group_key: 'badges', status: 'running', finished_at: nil)
    latest = described_class.latest_by_season_and_group(described_class.for_season(1))
    expect(latest[[1, 'badges']]).to eq(failed)
    expect(described_class.last_succeeded(season_id: 1, group_key: 'badges').status).to eq('succeeded')
  end

  it 'keeps only the last KEPT_PER_GROUP runs of a season and group' do
    stub_const('Ops::HealthRun::KEPT_PER_GROUP', 2)
    runs = FactoryBot.create_list(:ops_health_run, 4, season_id: 2, group_key: 'setup')
    expect(described_class.prune!(season_id: 2, group_key: 'setup')).to eq(2)
    expect(described_class.for_season(2).pluck(:id)).to match_array(runs.last(2).map(&:id))
  end
end
