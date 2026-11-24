# frozen_string_literal: true

require 'rails_helper'

# Phase 13 additions to the operations pages: the inspectors, the checklist-only clone, the form lookups, the progress
# and Cancel of a long run, the season-wide Fix button of a health section, the checklist link of season.setup.
RSpec.describe 'Maintenance pages (phase 13)' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:season) { closed_health_season }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  def page_body = response.parsed_body

  def season_fix_run(**attributes)
    FactoryBot.create(:ops_operation_run, operation_key: 'season.badge_fix', params: { 'season_id' => season.id }, season_id: season.id,
                                          label: 'Fix the badges', **attributes)
  end

  it 'lists the read-only inspectors apart, and the categories clone without a form link (checklist only)' do
    get(operations_path)
    expect(page_body.css('#operations-inspectors tr[data-operation-key]').pluck('data-operation-key')).to eq(Maintenance::Registry.inspector_keys)
    clone_row = page_body.at_css('#operations-list tr[data-operation-key="categories.clone"]')
    expect(clone_row.at_css('a[href="/operations/categories.clone/new"]')).to be_nil
    expect(clone_row.text).to include(I18n.t('maintenance.index.checklist_only'))
    expect(page_body.at_css("#operations-season-start-link[href='#{season_start_index_path}']")).to be_present
  end

  it 'renders the id fields with their local lookup and hides the rake-only params' do
    get(new_operation_path(key: 'meeting.merge', source_id: 1, dest_id: 5))
    form = page_body.at_css('#frm-operation')
    lookup = form.at_css('[data-controller="operation-lookup"][data-operation-lookup-domain-value="meetings"]')
    expect(lookup.at_css('input[name="operation[source_id]"]')['data-operation-lookup-target']).to eq('id')
    expect(lookup.at_css('input[data-operation-lookup-target="search"]')['name']).to be_blank
    expect(form.at_css('input[name="operation[console_output]"]')).to be_nil
    get(new_operation_path(key: 'team.check'))
    expect(page_body.at_css('#operation-form-inspector')).to be_present
  end

  it 'shows the progress and the Cancel button of a running long run, and cancels it' do
    run = season_fix_run(status: 'running', started_at: Time.current, progress: { 'done' => 3, 'total' => 12, 'label' => 'badge 5' })
    get(maintenance_run_path(run))
    expect(page_body.at_css('#operation-run-progress progress[value="3"][max="12"]').text).to eq('25%')
    expect(page_body.at_css("#frm-operation-cancel[action='#{cancel_maintenance_run_path(run)}']")).to be_present

    post(cancel_maintenance_run_path(run))
    expect(response).to redirect_to(maintenance_run_path(run))
    expect(flash[:info]).to eq(I18n.t('maintenance.run.cancel_requested'))
    expect(run.reload.cancel_requested_at).to be_present
    get(maintenance_run_path(run))
    expect(page_body.at_css('#operation-run-cancel-requested')).to be_present
  end

  it 'cancels a queued run at once and refuses the others' do
    queued = season_fix_run(status: 'queued')
    post(cancel_maintenance_run_path(queued))
    expect(flash[:info]).to eq(I18n.t('maintenance.run.cancelled'))
    expect(queued.reload).to have_attributes(status: 'refused', refusal_reason: 'cancelled')
    other = FactoryBot.create(:ops_operation_run, status: 'running')
    post(cancel_maintenance_run_path(other))
    expect(flash[:warning]).to eq(I18n.t('maintenance.run.cancel_refused'))
    expect(other.reload.cancel_requested_at).to be_nil
  end

  it 'says that an inspector run has nothing to apply' do
    run = FactoryBot.create(:ops_operation_run, operation_key: 'team.check', params: { 'source_id' => 1, 'dest_id' => 2 }, status: 'succeeded',
                                                console: 'report', finished_at: Time.current)
    get(maintenance_run_path(run))
    expect(page_body.at_css('#operation-run-outcome').text).to include(I18n.t('maintenance.run.inspector'))
    expect(page_body.at_css('#operation-apply')).to be_nil
  end

  it 'puts the season-wide badge fix on the sure duplicates section and the checklist link on season.setup findings' do
    FactoryBot.create(:ops_health_finding, season_id: season.id, group_key: 'badges', check_key: 'badges.duplicate.sure', subject_type: 'swimmer',
                                           payload: { 'rake' => { 'src' => 2, 'dest' => 1 }, 'title_args' => { 'name' => 'X', 'year' => 1970, 'count' => 2 } })
    get(health_section_path(season.id, 'badges.duplicate.sure'))
    expect(page_body.at_css(".health-season-fixes a[href='#{new_operation_path(key: 'season.badge_fix', season_id: season.id)}']")).to be_present

    setup = FactoryBot.create(:ops_health_finding, season_id: season.id, group_key: 'setup', check_key: 'season.setup', subject_type: 'season',
                                                   subject_id: season.id, payload: { 'season_id' => season.id, 'title_args' => { 'id' => season.id } })
    get(health_finding_path(setup))
    expect(page_body.at_css("a[data-health-action='season_start'][href='#{season_start_path(season.id)}']")).to be_present
  end

  it 'looks up swimmers, meetings and badges in the local DB, with a label' do
    get('/lookup/swimmers/142')
    expect(response.parsed_body).to include('id' => 142, 'label' => start_with(GogglesDb::Swimmer.find(142).complete_name))
    get('/lookup/meetings', params: { q: '18222' })
    expect(response.parsed_body.pluck('id')).to include(18_222)
    get('/lookup/badges/115303')
    expect(response.parsed_body).to include('id' => 115_303, 'team_id' => 1292)
    expect(response.parsed_body.keys).not_to include('created_at')
  end
end
