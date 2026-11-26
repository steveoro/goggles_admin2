# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe DashboardController do
  include AdminSignInHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { prepare_admin_user }
  let(:data_dir) { Pathname.new(Dir.mktmpdir) }
  let(:season) { GogglesDb::Season.last }
  let(:api_url) { Shell::APITarget.configured_url }
  let(:frame_paths) do
    {
      needs_you: dashboard_needs_you_path, in_progress: dashboard_in_progress_path, season_progress: dashboard_season_progress_path,
      system: dashboard_system_path, activity: dashboard_activity_path, kpis: dashboard_kpis_path
    }
  end
  let(:review_path) { data_dir.join('results.new', '262', 'meet-z.json').to_s }
  let(:board_rows) do
    [
      board_row('101', 'Trofeo Crawl', :link_not_crawled, next_action: next_action(:crawl, '101', url: 'https://fin.example/101')),
      board_row('102', 'Trofeo Review', :results_ready, next_action: next_action(:review_results, '102', file_path: review_path)),
      board_row('103', 'Trofeo Busy', :link_not_crawled, next_action: next_action(:crawl, '103'), busy: true),
      board_row('104', 'Trofeo Push', :sql_pending, next_action: next_action(:push, '104', sql_path: '/x.sql', sql_paths: ['/x.sql'])),
      board_row('105', 'Trofeo Done', :committed_with_results, meeting_id: 5)
    ]
  end
  let(:board_result) do
    SeasonBoard::Builder::Result.new(season:, rows: board_rows, orphans: [], unmatched_sources: [], snapshot_checked_at: nil,
                                     warnings: [], active_activities: [])
  end

  # (not memoized: several examples make more than one request)
  def html
    response.parsed_body
  end

  def board_row(fin_event_id, name, state, next_action: nil, **overrides)
    defaults = {
      fin_event_id:, key: "k#{fin_event_id}", date_text: '08/11', first_date: Date.new(2026, 11, 8), last_date: Date.new(2026, 11, 8),
      year: '2026', name:, place: 'Roma', url: "https://fin.example/#{fin_event_id}", info: nil, calendar_id: nil, meeting_id: nil,
      meeting_description: nil, meeting_header_date: nil, mir_count: 0, mrr_count: 0, results_acquired: false, state:,
      state_detail: {}, next_action:, activity: { crawl: nil, extract: nil }, busy: false, flags: [], calendar: nil, disk_entry: nil
    }
    SeasonBoard::Row.new(**defaults, **overrides)
  end

  def next_action(kind, fin_event_id, **params)
    SeasonBoard::NextAction.new(kind:, params: { fin_event_id: }.merge(params))
  end

  before(:each) do
    FileUtils.mkdir_p(data_dir.join('results.new', '262'))
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_dir)
    allow(SeasonBoard::Builder).to receive_messages(latest_season: season, new: instance_double(SeasonBoard::Builder, call: board_result))
    # (any remote call would raise: the dashboard must make none)
    allow(APIProxy).to receive(:call).and_raise(RuntimeError, 'no API call expected')
    allow(APIProxy).to receive(:ping).and_raise(RuntimeError, 'no API ping expected')
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path,
                    SystemStatus::CrawlerProbe.status_path, SystemStatus::CrawlerProbe.pid_path])
  end

  after(:each) do
    FileUtils.remove_entry(data_dir)
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path])
    Ops::Database.reset_state!
  end

  context 'with an unlogged user' do
    it 'redirects the page and every frame to the login path' do
      [root_path, home_index_path, activity_path, *frame_paths.values].each do |path|
        get(path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  context 'with a logged-in user (API calls raising)' do
    before(:each) { sign_in_admin(admin_user) }

    it 'renders the layout with one lazy frame per zone, without any API call' do
      get(root_path)
      expect(response).to have_http_status(:success)
      frame_paths.each_value { |path| expect(html.at_css("turbo-frame[src='#{path}']")).to be_present, path }
      expect(html.at_css('#dashboard[data-controller="live-frames"]')).to be_present
      expect(html.at_css('#btn-refresh-kpis')).to be_present
      expect(html.at_css('.app-sidebar a.nav-link.active')['href']).to eq(root_path)
    end

    it 'serves the old home URL too' do
      get(home_index_path)
      expect(response).to have_http_status(:success)
      expect(html.at_css('#dashboard')).to be_present
    end

    it 'returns 200 for every frame, rendered without the layout' do
      frame_paths.each do |zone, path|
        get(path)
        expect(response).to have_http_status(:success), "#{zone}: #{response.status}"
        expect(html.at_css('turbo-frame')).to be_present
        expect(html.at_css('.app-sidebar')).to be_nil
      end
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
    end

    describe 'GET needs_you' do
      it 'lists the board rows with a next action (not the busy ones nor the push ones), one button each' do
        get(dashboard_needs_you_path)
        keys = html.css('[data-inbox-key]').pluck('data-inbox-key')
        expect(keys).to include('board:101:crawl', 'board:102:review_results')
        expect(keys).not_to include('board:103:crawl', 'board:104:push')
        html.css('li.inbox-item').each do |item|
          expect(item.css('.inbox-item-actions > a.btn, .inbox-item-actions > form > button.btn').size).to eq(1), item.text
        end
      end

      it 'turns a raising source into one band-1 item instead of an error page' do
        allow(SeasonBoard::Builder).to receive(:new).and_raise(RuntimeError, 'board exploded')
        get(dashboard_needs_you_path)
        expect(response).to have_http_status(:success)
        failed = html.at_css('[data-inbox-key="inbox:board_rows:failed"]')
        expect(failed['data-inbox-band']).to eq('failed')
        expect(failed.text).to include('board exploded')
      end

      it 'shows the empty state when nothing needs the operator' do
        allow(SeasonBoard::Builder).to receive(:latest_season).and_return(nil)
        get(dashboard_needs_you_path)
        expect(html.at_css('#inbox-empty')).to be_present
      end
    end

    describe 'GET kpis' do
      let(:snapshot_key) { KpiRefreshJob.key_for(api_url) }

      it 'says "no data yet" without a snapshot for the API URL (never a 0)' do
        get(dashboard_kpis_path)
        expect(html.css('.kpi-tile').size).to eq(4)
        expect(html.css('.kpi-value')).to be_empty
        expect(html.css('.kpi-state').map { |node| node.text.strip }.uniq).to eq([I18n.t('dashboard.kpis.states.no_data')])
        expect(html.at_css('#kpi-strip-as-of').text).to include(api_url)
      end

      it 'shows "unreachable" for the counters never fetched from an unreachable API, never "0"' do
        Ops::Snapshot.write!(snapshot_key, { 'url' => api_url, 'status' => 'unreachable', 'values' => {}, 'fetched_at' => {},
                                             'errors' => { 'users' => 'Connection refused' } })
        get(dashboard_kpis_path)
        expect(html.css('.kpi-value')).to be_empty
        expect(html.css('.kpi-state').map { |node| node.text.strip }.uniq).to eq([I18n.t('dashboard.kpis.states.unreachable')])
        expect(html.css('.kpi-tile').map(&:text).join).not_to match(/\b0\b/)
      end

      it 'shows "sign in to refresh" next to the last known values without credentials, and distinguishes a real 0' do
        fetched = 1.hour.ago.iso8601
        Ops::Snapshot.write!(snapshot_key, { 'url' => api_url, 'status' => 'no_credentials',
                                             'values' => { 'users' => 87, 'issues' => 0 },
                                             'fetched_at' => { 'users' => fetched, 'issues' => fetched }, 'errors' => {} })
        get(dashboard_kpis_path)
        expect(html.at_css('#kpi-tile-users .kpi-value').text.strip).to eq('87')
        expect(html.at_css('#kpi-tile-issues .kpi-value').text.strip).to eq('0')
        expect(html.at_css('#kpi-tile-users .kpi-note').text).to include(I18n.t('dashboard.kpis.states.sign_in'))
        expect(html.at_css('#kpi-tile-api-uses .kpi-value')).to be_nil
        expect(html.at_css('#kpi-tile-api-uses .kpi-state').text.strip).to eq(I18n.t('dashboard.kpis.states.sign_in'))
        expect(html.at_css('#kpi-tile-users')['href']).to eq(api_users_path)
      end
    end

    it 'GET system lists one row per status probe, with "Start crawler" as a button' do
      File.write(SystemStatus::CrawlerProbe.pid_path, '999999999')
      get(dashboard_system_path)
      expect(html.css('.dashboard-status-row').pluck('data-status-key')).to eq(SystemStatus::Registry.probes.map { |p| p.key.to_s })
      crawler = html.at_css('#status-row-crawler')
      expect(crawler['data-status-level']).to eq('error')
      expect(crawler.at_css("form[action='#{sources_crawler_start_path}'] button")).to be_present
    ensure
      FileUtils.rm_f(SystemStatus::CrawlerProbe.pid_path)
    end

    it 'GET system shows the automation kill switches (phase 10) and the worker mode' do
      DataFix::Automation.store!(:auto_extract, false)
      get(dashboard_system_path)
      switches = html.css('#dashboard-automation [data-automation-switch]')
      expect(switches.to_h { |row| [row['data-automation-switch'], row['data-automation-state']] })
        .to eq('enabled' => 'on', 'auto_extract' => 'off', 'auto_prepare' => 'on')
      toggle = html.at_css("#dashboard-automation [data-automation-switch='auto_extract'] form[action='#{automation_switch_path}']")
      switch = toggle.at_css('input[type=checkbox][role=switch][name=value]')
      expect(switch['value']).to eq('1')
      expect(switch['checked']).to be_nil
      expect(toggle.at_css('input[type=hidden][name=value]')['value']).to eq('0')
      expect(html.at_css('#dashboard-automation #operations-switch-dashboard input[role=switch][checked]')).to be_present
      expect(html.at_css('#dashboard-worker-mode')).to be_present
    end

    it 'GET activity lists the latest events with a link to the whole log' do
      Ops.record_event!(kind: 'datafix.committed', level: 'success', actor: 'operator', subject_type: 'source',
                        subject_key: 'crawler/data/results.new/262/meet-lt4.json', link_path: '/data_fix/sessions')
      get(dashboard_activity_path)
      event = html.at_css('.activity-feed-event[data-event-kind="datafix.committed"]')
      expect(event.text).to include(I18n.t('ops.events.datafix.committed'), 'meet-lt4.json')
      expect(html.at_css('#activity-feed-all')['href']).to eq(activity_path)
    end

    it 'GET season_progress links each state to the filtered board' do
      get(dashboard_season_progress_path)
      expect(html.css('[data-state-chip]').pluck('href'))
        .to include(season_board_path(state: :link_not_crawled), season_board_path(state: :results_ready))
      expect(html.at_css('#season-progress').text).to include(season.description)
    end

    it 'GET in_progress shows the running board activity with the busy marker' do
      SeasonBoard::ActivityLog.new.start!('101', kind: :crawl, origin: :manual)
      get(dashboard_in_progress_path)
      expect(html.at_css('[data-live-busy="true"]')).to be_present
      expect(html.at_css('[data-activity-status="running"]').text).to include('FIN #101')
    end

    it 'GET /activity paginates the event log' do
      3.times { |i| Ops.record_event!(kind: 'board.crawl_finished', subject_type: 'fin_event', subject_key: "20#{i}") }
      get(activity_path)
      expect(response).to have_http_status(:success)
      expect(html.css('#activity-events tbody tr').size).to eq(3)
      expect(html.css('.breadcrumb-item').map { |node| node.text.strip }).to include(I18n.t('dashboard.title'))
    end

    it 'POST refresh_kpis queues a KpiRefreshJob and goes back to the dashboard' do
      expect { post(dashboard_refresh_kpis_path) }.to have_enqueued_job(KpiRefreshJob)
      expect(response).to redirect_to(root_path)
      expect(flash[:info]).to eq(I18n.t('dashboard.flash.kpis_queued'))
    end

    describe 'failed job actions' do
      # (plain doubles: the Solid Queue tables don't exist in the test DB, so the models can't be verified)
      let(:job) { double('SolidQueue::Job', class_name: job_class) } # rubocop:disable RSpec/VerifiedDoubles
      let(:execution) { double('SolidQueue::FailedExecution', job:, discard: true, retry: true) } # rubocop:disable RSpec/VerifiedDoubles
      let(:job_class) { 'KpiRefreshJob' }

      before(:each) do
        allow(Dashboard::QueueActivity).to receive(:failed_execution).with('7').and_return(execution)
        allow(Dashboard::QueueActivity).to receive(:failed_execution).with('8').and_return(nil)
      end

      it 'discards a failed execution' do
        post(dashboard_discard_failed_job_path, params: { id: 7 })
        expect(execution).to have_received(:discard)
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to include('KpiRefreshJob')
      end

      it 'retries a failed execution outside the protected list' do
        post(dashboard_retry_failed_job_path, params: { id: 7 })
        expect(execution).to have_received(:retry)
        expect(flash[:notice]).to include('KpiRefreshJob')
      end

      context 'with a protected job' do
        let(:job_class) { 'DataFixCommitJob' }

        it 'never retries it' do
          post(dashboard_retry_failed_job_path, params: { id: 7 })
          expect(execution).not_to have_received(:retry)
          expect(flash[:warning]).to eq(I18n.t('dashboard.flash.job_protected', job: 'DataFixCommitJob'))
        end
      end

      it 'says so when the execution is gone' do
        post(dashboard_discard_failed_job_path, params: { id: 8 })
        expect(flash[:warning]).to eq(I18n.t('dashboard.flash.job_not_found'))
      end
    end
  end

  context 'with an API-offline session' do
    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive(:call).and_raise(RuntimeError, 'no API call expected')
    end

    it 'renders the page and every frame, with the API-offline blocker first' do
      get(root_path)
      expect(response).to have_http_status(:success)
      frame_paths.each_value do |path|
        get(path)
        expect(response).to have_http_status(:success), path
      end

      get(dashboard_needs_you_path)
      first_item = html.at_css('li.inbox-item')
      expect(first_item['data-inbox-key']).to eq('blocker:api_offline')
      expect(first_item.at_css("a[href='#{settings_path}']")).to be_present

      get(dashboard_kpis_path)
      expect(html.css('a.kpi-tile')).to be_empty # (no links to the API grids in an offline session)
    end
  end

  context 'with the ops DB not available' do
    before(:each) do
      sign_in_admin(admin_user)
      allow(Ops::Database).to receive(:state).and_return(:missing)
    end

    it 'renders the page (with the setup notice) and every frame' do
      get(root_path)
      expect(response).to have_http_status(:success)
      expect(html.at_css('#sticky-alerts #ops-setup-notice')).to be_present
      frame_paths.each_value do |path|
        get(path)
        expect(response).to have_http_status(:success), path
      end
    end

    it 'reports it in the inbox, in the system zone and in the activity zone' do
      get(dashboard_needs_you_path)
      expect(html.at_css('[data-inbox-key="blocker:ops_db"]')).to be_present
      get(dashboard_system_path)
      expect(html.at_css('#status-row-ops-db')['data-status-level']).to eq('error')
      get(dashboard_activity_path)
      expect(html.at_css('#activity-feed-unavailable')).to be_present
      get(activity_path)
      expect(html.at_css('#activity-unavailable')).to be_present
    end
  end
end
