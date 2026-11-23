# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Data health pages' do
  include AdminSignInHelpers
  include ActiveJob::TestHelper

  let(:admin_user) { prepare_admin_user }
  let(:season) { closed_health_season }

  before(:each) { FactoryBot.create(:meeting, season:) }

  # (not memoized: several requests per example)
  def page_body = response.parsed_body

  def finding(**attributes)
    FactoryBot.create(:ops_health_finding, season_id: season.id, **attributes)
  end

  context 'with an unlogged user' do
    it 'redirects to the login page' do
      get(health_path)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with an API-offline session' do
    it 'reaches no health page (api_offline_allowed? stays false)' do
      sign_in_api_offline(admin_user)
      [health_path, health_matrix_path, health_season_path(season.id), dashboard_health_path].each_with_index do |path, index|
        get(path)
        next expect(response).to have_http_status(:success) if index == 3 # (the dashboard card frame is dashboard-wide)

        expect(response).to redirect_to(settings_path), path
      end
    end
  end

  context 'with a logged-in user' do
    before(:each) do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_raise('no API call expected')
    end

    it 'renders the matrix page layout with the local mirror label and the Run all button' do
      get(health_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#health-local-mirror').text).to include(I18n.t('health.local_mirror'))
      expect(page_body.at_css('#btn-health-run-all')).to be_present
      expect(page_body.at_css('turbo-frame#health-matrix')['src']).to eq(health_matrix_path)
      expect(page_body.at_css('#health-page')['data-live-frames-ping-ids-value']).to include('health-ping')
    end

    it 'shows the matrix counts per season and group, the running cells and the failed ones' do
      3.times { finding(severity: 'error') }
      finding(severity: 'warning', group_key: 'badges', check_key: 'badges.duplicate.possible')
      finding(status: 'acknowledged', group_key: 'people', check_key: 'swimmers.possible_duplicates', severity: 'warning')
      finding(status: 'resolved')
      FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'meetings', duration_ms: 400)
      FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'results', status: 'failed', error_message: 'boom')
      FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'setup', status: 'running', finished_at: nil)

      get(health_matrix_path)
      expect(response).to have_http_status(:success)
      cell = ->(group) { page_body.at_css("td[data-health-cell='#{season.id}-#{group}']") }
      expect(cell.call('meetings').text.strip).to eq('3 !')
      expect(cell.call('badges').text.strip).to eq('1 ~')
      expect(cell.call('people').text.strip).to eq(I18n.t('health.matrix.cell.ack', count: 1))
      expect(cell.call('results')['data-level']).to eq('failed')
      expect(cell.call('setup')['data-level']).to eq('pending')
      expect(page_body.at_css('#health-matrix-table')['data-live-busy']).to eq('true')
      expect(cell.call('meetings').at_css('a')['href']).to eq(health_season_path(season.id, anchor: 'health-group-meetings'))
    end

    it 'renders the season page with one lazy section per check and the run summary frame' do
      finding(severity: 'error')
      get(health_season_path(season.id))
      expect(response).to have_http_status(:success)
      sections = page_body.css('details.health-section')
      expect(sections.pluck('data-check-key')).to eq(Health::Registry.all.map(&:key))
      unflagged = page_body.at_css("##{Health::SectionComponent.dom_id_for('meetings.no_results.unflagged')}")
      expect(unflagged.attribute('open')).not_to be_nil
      expect(unflagged.at_css('.health-section-count').text).to eq('1')
      expect(unflagged.at_css('turbo-frame')['src']).to eq(health_section_path(season.id, 'meetings.no_results.unflagged'))
      expect(unflagged.at_css('turbo-frame')['loading']).to eq('lazy')
      expect(page_body.at_css('turbo-frame#health-season-summary')['src']).to eq(health_season_summary_path(season.id))
      expect(page_body.css('.app-breadcrumbs, nav[aria-label]').text).to include(I18n.t('health.title'))
    end

    it 'shows the per-group runs in the summary frame, with the failed run error and the re-run buttons' do
      FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'badges', status: 'failed', error_message: 'NoMethodError: x')
      get(health_season_summary_path(season.id))
      expect(response).to have_http_status(:success)
      row = page_body.at_css('tr[data-health-group="badges"]')
      expect(row.at_css('.health-run-error').text).to include('NoMethodError')
      expect(page_body.css('button[data-health-rerun], input[data-health-rerun]').size).to eq(Ops::HealthRun::GROUPS.size)
    end

    it 'returns 404 for an unknown season or check' do
      get(health_season_path(0))
      expect(response).to have_http_status(:not_found)
      get(health_section_path(season.id, 'meetings.unknown_check'))
      expect(response).to have_http_status(:not_found)
    end

    it 'lists the section findings (open by default), filtered by severity and text, with the bulk form' do
      error = finding(severity: 'error', title: 'Meeting 1 Trofeo Alfa')
      warning = finding(severity: 'warning', title: 'Meeting 2 Trofeo Beta')
      finding(status: 'ignored', note: 'fine')
      key = 'meetings.no_results.unflagged'

      get(health_section_path(season.id, key))
      expect(response).to have_http_status(:success)
      ids = page_body.css('input.health-finding-select').map { |node| node['value'].to_i }
      expect(ids).to contain_exactly(error.id, warning.id)
      expect(page_body.at_css("form#health-bulk-#{key.parameterize}")).to be_present
      expect(page_body.at_css('.health-howto').text).to eq(Health::Registry.fetch(key).howto)

      get(health_section_path(season.id, key, health_findings_grid: { severity: 'warning' }))
      expect(page_body.css('input.health-finding-select').map { |node| node['value'].to_i }).to eq([warning.id])
      get(health_section_path(season.id, key, health_findings_grid: { search: 'Alfa' }))
      expect(page_body.css('input.health-finding-select').map { |node| node['value'].to_i }).to eq([error.id])
      get(health_section_path(season.id, key, health_findings_grid: { status: 'visible' }))
      expect(page_body.css('input.health-finding-select').size).to eq(3)
    end

    it 'shows a finding with its how-to, the rake command with the ids filled in, the entity links and the cancel button' do
      flagged = finding(check_key: 'meetings.results_flag', severity: 'warning', subject_type: 'season', subject_id: season.id,
                        payload: { 'title_args' => { 'id' => season.id, 'count' => 3 }, 'rake' => { 'season_id' => season.id },
                                   'meeting_ids' => [7, 8, 9] })
      get(health_finding_path(flagged))
      expect(response).to have_http_status(:success)
      expect(page_body.at_css("#health-rake-#{flagged.id}").text.strip).to eq("bin/rails season_board:backfill season=#{season.id}")
      expect(page_body.at_css('#health-finding-howto').text).to include(Health::Registry.fetch('meetings.results_flag').howto)
      expect(page_body.at_css('h1').text).to include(I18n.t('health.checks.meetings.results_flag.finding', id: season.id, count: 3))

      unflagged = finding(payload: { 'cancel' => { 'meeting_id' => 7 }, 'meeting_id' => 7, 'description' => 'Trofeo',
                                     'title_args' => { 'id' => 7, 'date' => '-', 'description' => 'x' } })
      get(health_finding_path(unflagged))
      expect(page_body.at_css('a[data-health-action="cancel"]')['href']).to eq(new_health_cancellation_path(finding_id: unflagged.id))
      expect(page_body.at_css('a[data-health-entity="meeting"]')['href']).to start_with(api_meetings_path)
    end

    it 'shows the stale-data mark and the NULL-swimmers warning when they apply' do
      run = FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'results', db_epoch: 0)
      dup = finding(check_key: 'results.duplicates', group_key: 'results', last_seen_run_id: run.id,
                    payload: { 'null_swimmers_first' => true, 'rake' => { 'meeting_id' => 3 },
                               'title_args' => { 'id' => 3, 'description' => 'x', 'total' => 2 } })
      get(health_finding_path(dup))
      expect(page_body.at_css('#health-null-swimmers-first')).to be_present
      expect(page_body.at_css('#health-finding-howto').text).to include(I18n.t('health.finding.stale'))
    end

    it 'renders the dashboard card with the board season errors and the closed seasons with errors' do
      board = FactoryBot.create(:season)
      allow(SeasonBoard::Builder).to receive(:latest_season).and_return(board)
      FactoryBot.create(:ops_health_finding, season_id: board.id, severity: 'error')
      2.times { finding(severity: 'error') }
      FactoryBot.create(:ops_health_run, season_id: season.id)
      get(dashboard_health_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#health-card-current').text).to include(I18n.t('health.card.errors', count: 1))
      expect(page_body.at_css('#health-card-closed').text).to include(I18n.t('health.card.closed_errors', count: 2, seasons: 1))
    end
  end
end
