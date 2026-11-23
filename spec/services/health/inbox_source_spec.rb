# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::InboxSource do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.current }
  let(:context) { Inbox::Context.new(season: nil, board_snapshot: nil, now:, ops_available: true) }

  def items = described_class.new.items(context)

  def finding(season_id, group_key, check_key, severity, **attributes)
    FactoryBot.create(:ops_health_finding, season_id:, group_key:, check_key:, severity:, **attributes)
  end

  it 'is registered under :health, enabled only with the ops DB, with the report as "more" path' do
    expect(Inbox::Registry.sources).to include(described_class)
    expect(described_class.key).to eq(:health)
    expect(described_class.enabled?(Inbox::Context.new(season: nil, board_snapshot: nil, ops_available: false))).to be(false)
    expect(described_class.more_path).to eq('/health')
  end

  it 'groups the open errors per season and group, adds one item for all the warnings, never one per finding' do
    FactoryBot.create(:ops_health_run, season_id: 252, finished_at: now - 1.hour)
    3.times { finding(252, 'meetings', 'meetings.no_results.unflagged', 'error') }
    finding(252, 'meetings', 'calendars.unlinked', 'error', first_seen_at: now - 3.days)
    finding(252, 'meetings', 'calendars.unlinked', 'error', status: 'acknowledged')
    finding(242, 'badges', 'badges.duplicate.sure', 'error')
    2.times { finding(242, 'people', 'swimmers.possible_duplicates', 'warning') }
    finding(232, 'results', 'results.dup_mir_per_badge', 'warning')

    by_key = items.index_by(&:key)
    expect(by_key.keys).to contain_exactly('health:252:meetings', 'health:242:badges', 'health:warnings')
    meetings = by_key['health:252:meetings']
    expect(meetings).to have_attributes(band: :notice, count: 4, source: :health)
    expect(meetings.title).to eq(I18n.t('inbox.health.errors_title', season: 252, group: I18n.t('health.groups.meetings'), count: 4))
    expect(meetings.detail).to start_with("3 × #{Health::Registry.fetch('meetings.no_results.unflagged').title}")
    expect(meetings.since).to be_within(1.second).of(now - 3.days)
    expect(meetings.action.path).to eq('/health/seasons/252#health-group-meetings')
    expect(by_key['health:warnings']).to have_attributes(count: 3, title: I18n.t('inbox.health.warnings_title', count: 3, seasons: 2))
  end

  it 'adds one item per group whose latest run failed, with a Re-run POST' do
    FactoryBot.create(:ops_health_run, season_id: 252, group_key: 'badges', finished_at: now - 2.hours)
    FactoryBot.create(:ops_health_run, season_id: 252, group_key: 'badges', status: 'failed', error_message: 'boom', finished_at: now - 1.hour)
    FactoryBot.create(:ops_health_run, season_id: 252, group_key: 'results', status: 'failed', finished_at: now - 3.hours)
    FactoryBot.create(:ops_health_run, season_id: 252, group_key: 'results', finished_at: now - 1.hour)
    failed = items.select { |item| item.kind == :health_run_failed }
    expect(failed.map(&:key)).to eq(['health:failed:252:badges'])
    expect(failed.first).to have_attributes(band: :failed, detail: 'boom')
    expect(failed.first.secondary_action).to have_attributes(http_method: :post, path: '/health/runs')
    expect(failed.first.secondary_action.params).to include(season_id: 252, group: 'badges')
  end

  it 'warns when no run finished for 8 days or when runs stay stuck in the queue, never before the first run' do
    expect(items).to eq([])
    FactoryBot.create(:ops_health_run, finished_at: now - 9.days, created_at: now - 9.days)
    expect(items.sole).to have_attributes(kind: :health_overdue, band: :failed, key: 'health:overdue')
    FactoryBot.create(:ops_health_run, finished_at: now - 1.day)
    expect(items).to eq([])
    FactoryBot.create(:ops_health_run, status: 'queued', finished_at: nil, created_at: now - 4.hours)
    expect(items.sole).to have_attributes(kind: :health_stuck, band: :failed)
  end

  it 'reads the ops DB only' do
    FactoryBot.create(:ops_health_run, finished_at: now)
    finding(252, 'meetings', 'meetings.no_results.unflagged', 'error')
    context # (the Inbox::Context itself reads the API URL setting)
    expect(primary_db_statements { items }).to be_empty
  end
end
