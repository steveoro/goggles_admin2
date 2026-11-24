# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::FindingSync do
  let(:season_id) { 242 }

  def new_run(group_key = 'meetings')
    FactoryBot.create(:ops_health_run, season_id:, group_key:)
  end

  def unflagged(meeting_id, description: 'Trofeo X')
    Health::Finding.new(check_key: 'meetings.no_results.unflagged', severity: 'error', subject_type: 'meeting',
                        subject_id: meeting_id, identity: "meeting:#{meeting_id}",
                        title_args: { id: meeting_id, date: '2025-03-08', description: },
                        payload: { meeting_id:, description: })
  end

  def sync(findings, run: new_run)
    described_class.new(run:, findings:).call
  end

  def row_for(meeting_id)
    Ops::HealthFinding.find_by(season_id:, subject_id: meeting_id)
  end

  it 'creates open findings with fingerprint, title, digest and first/last seen run' do
    run = new_run
    result = sync([unflagged(1), unflagged(2)], run:)
    expect(result).to have_attributes(findings_count: 2, new_count: 2, resolved_count: 0)
    expect(result.counts['meetings.no_results.unflagged']).to eq('open' => 2, 'seen' => 2, 'new' => 2, 'resolved' => 0)
    expect(result.counts.keys).to match_array(Health::Registry.for_group('meetings').map(&:key))
    row = row_for(1)
    expect(row).to have_attributes(status: 'open', severity: 'error', group_key: 'meetings', subject_type: 'meeting',
                                   first_seen_run_id: run.id, last_seen_run_id: run.id,
                                   fingerprint: Ops::HealthFinding.fingerprint_for(check_key: 'meetings.no_results.unflagged',
                                                                                   season_id:, identity: 'meeting:1'))
    expect(row.title).to eq('Meeting 1 (2025-03-08) Trofeo X: no results, not cancelled')
    expect(row.payload['title_args']).to include('id' => 1)
    expect(row.payload_digest).to eq(Ops::HealthFinding.digest_for(row.payload))
  end

  it 'keeps the id and the status of a finding seen again, refreshing its last seen run' do
    sync([unflagged(1)])
    row = row_for(1)
    row.update!(status: 'acknowledged', note: 'known')
    second = new_run
    result = sync([unflagged(1)], run: second)
    expect(result.new_count).to eq(0)
    expect(row.reload).to have_attributes(id: row.id, status: 'acknowledged', note: 'known', last_seen_run_id: second.id)
  end

  it 'resolves the unseen open and acknowledged findings, keeping the ignored ones' do
    sync([unflagged(1), unflagged(2), unflagged(3)])
    row_for(2).update!(status: 'acknowledged')
    row_for(3).update!(status: 'ignored', note: 'no results published')
    result = sync([])
    expect(result.resolved_count).to eq(2)
    expect([row_for(1), row_for(2)].map(&:status)).to eq(%w[resolved resolved])
    expect(row_for(1).resolved_at).to be_present
    expect(row_for(3)).to have_attributes(status: 'ignored', note: 'no results published')
  end

  it 'reopens an acknowledged finding whose payload changed; an ignored one stays ignored' do
    sync([unflagged(1), unflagged(2)])
    row_for(1).update!(status: 'acknowledged')
    row_for(2).update!(status: 'ignored', note: 'fine')
    result = sync([unflagged(1, description: 'Trofeo Y'), unflagged(2, description: 'Trofeo Z')])
    expect(row_for(1)).to have_attributes(status: 'open', title: include('Trofeo Y'))
    expect(row_for(2)).to have_attributes(status: 'ignored', note: 'fine', title: include('Trofeo Z'))
    expect(result.new_count).to eq(1)
  end

  it 'reopens a resolved finding seen again, keeping its note' do
    sync([unflagged(1)])
    row_for(1).update!(note: 'checked once')
    sync([])
    expect(row_for(1).status).to eq('resolved')
    sync([unflagged(1)])
    expect(row_for(1)).to have_attributes(status: 'open', note: 'checked once', resolved_at: nil)
  end

  it 'touches only the findings of the run season and group' do
    other_season = FactoryBot.create(:ops_health_finding, season_id: 252)
    other_group = FactoryBot.create(:ops_health_finding, season_id:, group_key: 'badges', check_key: 'badges.duplicate.sure')
    sync([])
    expect([other_season.reload.status, other_group.reload.status]).to eq(%w[open open])
  end

  it 'prunes the findings resolved more than 180 days ago' do
    old = FactoryBot.create(:ops_health_finding, season_id: 252, status: 'resolved', resolved_at: 181.days.ago)
    recent = FactoryBot.create(:ops_health_finding, season_id: 252, status: 'resolved', resolved_at: 10.days.ago)
    sync([])
    expect(Ops::HealthFinding.exists?(old.id)).to be(false)
    expect(Ops::HealthFinding.exists?(recent.id)).to be(true)
  end
end
