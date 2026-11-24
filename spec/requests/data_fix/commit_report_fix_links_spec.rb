# frozen_string_literal: true

require 'rails_helper'

# Phase 11: the persistent commit report offers the Fix links of the badge / duplicate findings (always through the
# prefilled operation form: dry run first).
RSpec.describe 'Commit report Fix links' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:season_id) { 242 }
  let(:meeting_id) { 19_412 }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  def report(**attributes)
    Ops::CommitReport.create!(source_base: 'spec-meeting', source_path: '/tmp/spec-meeting-lt4.json', status: 'committed', season_id:,
                              meeting_id:, requested_by_user_id: admin_user.id, requested_at: Time.current, **attributes)
  end

  def finding(check_key, group_key, **attributes)
    FactoryBot.create(:ops_health_finding, season_id:, check_key:, group_key:, **attributes)
  end

  it 'lists the open badge findings of the season and the duplicate findings of the meeting, with their Fix buttons, once the runs are over' do
    run = FactoryBot.create(:ops_health_run, season_id:, group_key: 'results', status: 'succeeded')
    sure = finding('badges.duplicate.sure', 'badges', subject_type: 'swimmer', payload: { 'rake' => { 'src' => 2, 'dest' => 1 } })
    dup = finding('results.duplicates', 'results', subject_id: meeting_id, payload: { 'meeting_id' => meeting_id })
    finding('results.duplicates', 'results', subject_id: meeting_id + 1)
    finding('badges.duplicate.sure', 'badges', status: 'resolved')
    get(data_fix_commit_report_health_path(report(health_run_ids: { 'results' => run.id })))
    expect(response).to have_http_status(:success)
    rows = response.parsed_body.css('#commit-report-fixes li[data-finding-id]')
    expect(rows.map { |row| row['data-finding-id'].to_i }).to eq([dup.id, sure.id])
    expect(rows.first.at_css('a[data-operation-key="results.dedupe"]')['href']).to eq(new_operation_path(key: 'results.dedupe', finding_id: dup.id))
    expect(rows.last.at_css('a[data-operation-key="badge.merge"]')['href']).to eq(new_operation_path(key: 'badge.merge', finding_id: sure.id))
  end

  it 'shows no Fix list while a health run is pending' do
    run = FactoryBot.create(:ops_health_run, season_id:, group_key: 'results', status: 'queued')
    finding('results.duplicates', 'results', subject_id: meeting_id)
    get(data_fix_commit_report_health_path(report(health_run_ids: { 'results' => run.id })))
    expect(response.parsed_body.at_css('#commit-report-fixes')).to be_nil
  end

  it 'adds the Fix links to the legacy post-commit checks' do
    checks = { overall_status: 'error', season_id:,
               badge_season_check: { status: 'error', sure_badge_merges_count: 1,
                                     sure_badge_merges: [{ swimmer_id: 5, swimmer_name: 'X', badges: [{ id: 21 }, { id: 13 }] }] },
               duplicate_results_check: { status: 'error', meetings_with_findings_count: 1,
                                          meetings_with_findings: [{ meeting_id:, meeting_description: 'Trofeo', counts: { mirs: 2 } }] } }
    get(data_fix_commit_report_path(report(post_commit_checks: checks)))
    expect(response).to have_http_status(:success)
    body = response.parsed_body
    expect(body.at_css('a[data-operation-key="badge.merge"]')['href'])
      .to eq(new_operation_path(key: 'badge.merge', source_id: 21, dest_id: 13, autofix: true, origin: 'commit_report'))
    expect(body.at_css('a[data-operation-key="results.dedupe"]')['href'])
      .to eq(new_operation_path(key: 'results.dedupe', meeting_id:, origin: 'commit_report'))
  end
end
