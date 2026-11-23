# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::SweepJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse('2026-11-23 10:45') }
  let(:current) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
  let(:closed_entries) do
    [252, 242, 232].map do |id|
      Health::SeasonScope::Entry.new(season_id: id, description: "Season #{id}", begin_date: Date.new(2000 + (id / 10), 10, 1),
                                     end_date: Date.new(2001 + (id / 10), 9, 30), status: :closed, meetings_count: 10, badges_count: 10)
    end
  end
  let(:no_data) do
    Health::SeasonScope::Entry.new(season_id: 12, description: 'Empty', begin_date: Date.new(2001, 10, 1), end_date: Date.new(2002, 9, 30),
                                   status: :closed, meetings_count: 0, badges_count: 0)
  end
  let(:current_entry) { health_entry(current, status: :current) }
  let(:scope) do
    instance_double(Health::SeasonScope, current: [current_entry], upcoming: [], closed: closed_entries + [no_data])
  end

  def ok_run(season_id, group, finished_at, status: 'succeeded')
    FactoryBot.create(:ops_health_run, season_id:, group_key: group, status:, finished_at:, created_at: finished_at)
  end

  def sweep(at = now)
    travel_to(at) { described_class.perform_now(now: at, scope:) }
  end

  it 'runs on the maintenance queue' do
    expect(described_class.new.queue_name).to eq('maintenance')
  end

  it 'enqueues the current season groups whose last run is 25 hours old, at the sweep priority, and stores the sweep time' do
    Ops::HealthRun::GROUPS.each { |group| ok_run(262, group, now - 25.hours) }
    closed_entries.each { |entry| Ops::HealthRun::GROUPS.each { |group| ok_run(entry.season_id, group, now - 1.day) } }
    result = nil
    expect { result = sweep }.to have_enqueued_job(Health::SeasonRunJob).exactly(5).times
    expect(result[:daily].map(&:group_key)).to match_array(Ops::HealthRun::GROUPS)
    expect(result[:daily].map(&:trigger).uniq).to eq(['scheduled'])
    expect(result[:closed_season_id]).to be_nil
    expect(enqueued_jobs.pluck(:priority).uniq).to eq([Health::SeasonRunJob::PRIORITY_SWEEP])
    expect(described_class.last_sweep_at).to eq(now)
  end

  it 'does not run the current season before 06:30, nor twice the same day' do
    closed_entries.each { |entry| Ops::HealthRun::GROUPS.each { |group| ok_run(entry.season_id, group, now - 1.day) } }
    expect(sweep(Time.zone.parse('2026-11-23 05:45'))[:daily]).to eq([])
    Ops::HealthRun::GROUPS.each { |group| ok_run(262, group, Time.zone.parse('2026-11-23 06:46')) }
    expect(sweep[:daily]).to eq([])
  end

  it 'records a skipped run for a closed season whose heavy groups have an unchanged stamp' do
    Ops::HealthRun::GROUPS.each { |group| ok_run(262, group, now - 1.hour) }
    season = closed_health_season
    entry = health_entry(season, status: :closed)
    allow(scope).to receive(:closed).and_return([entry])
    allow(Health::SeasonScope).to receive(:new).and_return(instance_double(Health::SeasonScope, entry:))
    stamp = Health::Stamp.new(season_id: season.id).digest
    Ops::HealthRun::GROUPS.each do |group|
      FactoryBot.create(:ops_health_run, season_id: season.id, group_key: group, finished_at: now - 8.days, created_at: now - 8.days,
                                         stamp:, check_versions: Health::Registry.versions_for(group))
    end

    expect(sweep[:closed_season_id]).to eq(season.id)
    perform_enqueued_jobs
    latest = Ops::HealthRun.latest_by_season_and_group(Ops::HealthRun.for_season(season.id))
    expect(latest.transform_keys(&:last).transform_values(&:status))
      .to eq('badges' => 'skipped', 'people' => 'skipped', 'results' => 'skipped', 'meetings' => 'succeeded', 'setup' => 'succeeded')
  end

  it 'catches up one closed season per heartbeat after the machine was off for 10 days' do
    Ops::HealthRun::GROUPS.each { |group| ok_run(262, group, now - 10.days) }
    closed_entries.each do |entry|
      Ops::HealthRun::GROUPS.each { |group| ok_run(entry.season_id, group, entry.season_id == 232 && group == 'setup' ? now - 30.days : now - 10.days) }
    end

    first = sweep
    expect(first[:daily].size).to eq(5)
    expect(first[:daily].map(&:trigger).uniq).to eq(['catch_up'])
    expect(first[:closed_season_id]).to eq(232)
    # the next heartbeat waits while that closed season is still pending:
    expect(sweep(now + 1.hour)[:closed_season_id]).to be_nil

    Ops::HealthRun.pending.update_all(status: 'succeeded', finished_at: now + 70.minutes) # rubocop:disable Rails/SkipsModelValidations
    expect(sweep(now + 2.hours)[:closed_season_id]).to eq(252)
    Ops::HealthRun.pending.update_all(status: 'succeeded', finished_at: now + 130.minutes) # rubocop:disable Rails/SkipsModelValidations
    expect(sweep(now + 3.hours)[:closed_season_id]).to eq(242)
  end

  it 'runs a never-checked closed season first, newest first, and never a "no data" season' do
    Ops::HealthRun::GROUPS.each { |group| ok_run(262, group, now - 1.hour) }
    expect(sweep[:closed_season_id]).to eq(252)
    expect(Ops::HealthRun.for_season(12)).to be_empty
  end
end
