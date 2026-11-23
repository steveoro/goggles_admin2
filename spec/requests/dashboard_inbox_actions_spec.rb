# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Exit criterion of the dashboard inbox: every item has exactly one primary action, and it lands on the right page
# with the right context. One example per v1 source: render the "Needs you" frame, read the item's button and follow
# it (a real request for the POST/DELETE actions and the plain pages; route recognition for the Data-Fix steps,
# whose pages need real files).
RSpec.describe 'Dashboard inbox actions' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:season) { GogglesDb::Season.last }
  let(:tmp_root) { Pathname.new(Dir.mktmpdir) }
  # (under a 'crawler/' folder, like the real one: the Push page path is relative to it)
  let(:data_dir) { tmp_root.join('crawler', 'data') }
  let(:season_dir) { data_dir.join('results.new', season.id.to_s) }
  let(:rows) { [] }
  let(:unmatched) { [] }
  let(:summary) do
    payload = {
      'season_id' => season.id, 'built_at' => Time.current.iso8601, 'state_counts' => {}, 'rows' => rows,
      'unmatched_sources' => unmatched, 'board_sql_paths' => [], 'warnings' => []
    }
    SeasonBoard::Snapshot::Summary.from_payload(payload, stored: true, taken_at: Time.current)
  end

  def row_payload(fin_event_id, name, state, kind, **params)
    { 'fin_event_id' => fin_event_id, 'name' => name, 'state' => state.to_s, 'url' => "https://fin.example/#{fin_event_id}",
      'last_date' => '2026-11-08', 'next_action' => kind && { 'kind' => kind.to_s, 'params' => { 'fin_event_id' => fin_event_id }.merge(params) } }
  end

  # The inbox item with the key, from the "Needs you" frame.
  def inbox_item(key)
    get(dashboard_needs_you_path)
    expect(response).to have_http_status(:success)
    item = response.parsed_body.at_css("li.inbox-item[data-inbox-key='#{key}']")
    expect(item).to be_present, "no inbox item #{key} in: #{response.parsed_body.css('[data-inbox-key]').pluck('data-inbox-key')}"
    item
  end

  # [http_method, path, params] of the item's one primary action.
  def primary_action(item)
    buttons = item.css('.inbox-item-actions > a.btn:not(.btn-link), .inbox-item-actions > form > button.btn:not(.btn-link)')
    expect(buttons.size).to eq(1)
    button = buttons.first
    return [:get, button['href'], {}] if button.name == 'a'

    form = button.ancestors('form').first
    inputs = form.css('input[type=hidden]').to_h { |input| [input['name'], input['value']] }
    method = (inputs.delete('_method') || form['method']).downcase.to_sym
    inputs.delete('authenticity_token')
    [method, form['action'], inputs]
  end

  def recognized(path)
    uri = URI(path)
    Rails.application.routes.recognize_path(uri.path).merge(Rack::Utils.parse_query(uri.query.to_s).symbolize_keys)
  end

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_dir)
    allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
    allow(SeasonBoard::Snapshot).to receive(:fetch).and_return(summary)
    allow(APIProxy).to receive(:call).and_raise(RuntimeError, 'no API call expected')
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path])
    sign_in_admin(admin_user)
  end

  after(:each) do
    FileUtils.remove_entry(tmp_root)
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path])
  end

  describe 'BoardRows' do
    let(:review_file) { season_dir.join('meet.json').to_s }
    let(:rows) do
      [row_payload('101', 'Trofeo Crawl', :link_not_crawled, :crawl, 'url' => 'https://fin.example/101'),
       row_payload('102', 'Trofeo Review', :in_review, :resume_review, 'file_path' => review_file, 'phase' => 3)]
    end

    it 'crawl: POSTs the FIN event id to the board, which queues the crawl and shows the board' do
      allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
      method, path, params = primary_action(inbox_item('board:101:crawl'))
      expect([method, path, params]).to eq([:post, season_board_crawl_path, { 'fin_event_id' => '101' }])

      post(path, params:)
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: season.id, fin_event_id: '101',
                                                                    url: 'https://fin.example/101', origin: :manual)
      expect(response).to redirect_to(season_board_path)
    end

    it 'resume_review: opens the Data-Fix step of the session, on its source file' do
      method, path, = primary_action(inbox_item('board:102:resume_review'))
      expect(method).to eq(:get)
      expect(recognized(path)).to include(controller: 'data_fix/swimmers', action: 'review_swimmers', file_path: review_file)
    end
  end

  describe 'UnmatchedSources' do
    let(:source_file) { season_dir.join('no-fin-lt4.json').to_s }
    let(:unmatched) do
      [{ 'base' => 'no-fin', 'bases' => ['no-fin'], 'pending' => 'source', 'review_path' => source_file, 'phase' => nil,
         'paths' => [source_file] },
       { 'base' => 'only-pdf', 'bases' => ['only-pdf'], 'pending' => 'manifest', 'review_path' => nil, 'phase' => nil,
         'paths' => [data_dir.join('manifests', 'manifest-only-pdf.pdf').to_s] }]
    end

    it 'opens a source without FIN id in the Data-Fix Phase 1 review' do
      method, path, = primary_action(inbox_item('unmatched:no-fin'))
      expect(method).to eq(:get)
      expect(recognized(path)).to include(controller: 'data_fix/sessions', action: 'review_sessions', file_path: source_file)
    end

    it 'sends a manifest-only entry to the Result files page' do
      _method, path, = primary_action(inbox_item('unmatched:only-pdf'))
      expect(path).to eq(pull_result_files_path)
    end
  end

  describe 'DataFixSessions' do
    let(:gone_source) { 'crawler/data/results.new/9996/gone-lt4.json' }

    after(:each) { GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: gone_source).delete_all }

    it 'purges the staging rows of a source whose file is gone (DELETE with confirm), back on the sessions list' do
      GogglesDb::DataImportMeetingRelayResult.create!(import_key: 'inbox-gone', phase_file_path: gone_source, rank: 1)
      item = inbox_item("session:#{gone_source}:purge")
      expect(item.at_css('form')['data-turbo-confirm']).to be_present
      method, path, params = primary_action(item)
      expect([method, path, params]).to eq([:delete, data_fix_sessions_purge_path, { 'source_path' => gone_source }])

      delete(path, params:)
      expect(response).to redirect_to(data_fix_sessions_path)
      expect(GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: gone_source)).to be_none
    end

    it 'resumes a session idle for 3 days or more at its highest step' do
      File.write(season_dir.join('idle-lt4.json'), '{}')
      phase_file = season_dir.join('idle-lt4-phase4.json')
      File.write(phase_file, '{}')
      File.utime(4.days.ago.to_time, 4.days.ago.to_time, phase_file)
      source = season_dir.join('idle-lt4.json').to_s # (outside Rails.root: kept absolute by DataFix::SessionIndex)

      method, path, = primary_action(inbox_item("session:#{source}"))
      expect(method).to eq(:get)
      expect(recognized(path)).to include(controller: 'data_fix/events', action: 'review_events', file_path: source)
    end
  end

  describe 'PendingSql' do
    it 'opens the Push page on the folder of the oldest script' do
      File.write(season_dir.join('0043-later-lt4.sql'), '')
      File.write(season_dir.join('0042-first-lt4.sql'), '')
      item = inbox_item('pending_sql')
      expect(item.text).to include('0042')

      method, path, = primary_action(item)
      expect(method).to eq(:get)
      expect(recognized(path)).to include(controller: 'push', action: 'index', curr_dir: "data/results.new/#{season.id}")
    end
  end

  describe 'FailedJobs' do
    let(:rows) { [row_payload('101', 'Trofeo Crawl', :link_not_crawled, :crawl, 'url' => 'https://fin.example/101')] }

    it 'retries a failed board crawl with a POST to the same board action (replacing the crawl item)' do
      log = SeasonBoard::ActivityLog.new
      log.queue!('101', kind: :crawl, origin: :auto)
      log.finish!('101', kind: :crawl, status: :failed, message: 'Timeout')
      allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)

      item = inbox_item('board:101:crawl')
      expect(item['data-inbox-band']).to eq('failed')
      method, path, params = primary_action(item)
      post(path, params:)
      expect(method).to eq(:post)
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(hash_including(fin_event_id: '101'))
      expect(response).to redirect_to(season_board_path)
    end

    it 'discards a failed Solid Queue job (Retry as the secondary action only for unprotected jobs)' do
      failed = Dashboard::QueueActivity::Failed.new(id: 7, job_id: 70, class_name: 'KpiRefreshJob', queue_name: 'default',
                                                    exception_class: 'RuntimeError', message: 'boom', created_at: 1.hour.ago)
      protected_failure = failed.with(id: 8, class_name: 'DataFixCommitJob')
      allow(Dashboard::QueueActivity).to receive(:new).and_return(instance_double(Dashboard::QueueActivity, failed: [failed, protected_failure]))
      execution = double('SolidQueue::FailedExecution', job: double(class_name: 'KpiRefreshJob'), discard: true) # rubocop:disable RSpec/VerifiedDoubles
      allow(Dashboard::QueueActivity).to receive(:failed_execution).with('7').and_return(execution)

      item = inbox_item('job:7')
      expect(item.at_css("form[action='#{dashboard_retry_failed_job_path}'] button.btn-link")).to be_present
      expect(inbox_item('job:8').at_css("form[action='#{dashboard_retry_failed_job_path}']")).to be_nil

      method, path, params = primary_action(inbox_item('job:7'))
      expect([method, path, params]).to eq([:post, dashboard_discard_failed_job_path, { 'id' => '7' }])
      post(path, params:)
      expect(execution).to have_received(:discard)
      expect(response).to redirect_to(root_path)
    end
  end

  describe 'FINChange' do
    it 'opens the Season board' do
      FedernuotoWatch::StateStore.new.update do |state|
        state.merge('change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'name' => 'New meeting' }] })
      end
      method, path, = primary_action(inbox_item('fin_change'))
      expect([method, path]).to eq([:get, season_board_path])
    end
  end

  describe 'Blockers' do
    it 'asks to sign in again (DELETE of the session) when the background credentials expired' do
      allow(Ops::BackgroundCredentials).to receive(:status).and_return(:expired)
      method, path, = primary_action(inbox_item('blocker:credentials'))
      expect([method, path]).to eq([:delete, destroy_user_session_path])

      delete(path)
      expect(response).to redirect_to(root_path).or redirect_to(new_user_session_path)
    end

    it 'links the job queue blocker to the docs (new tab)' do
      result = SystemStatus::Result.new(key: :queue, label: 'Jobs', level: :error, detail: 'No live supervisor')
      allow(SystemStatus::QueueProbe).to receive(:new).and_return(instance_double(SystemStatus::QueueProbe, call: result))
      item = inbox_item('blocker:queue')
      link = item.at_css('.inbox-item-actions > a.btn')
      expect(link['href']).to start_with('https://github.com/').and end_with('#background-jobs')
      expect(link['target']).to eq('_blank')
    end
  end

  describe 'Drift' do
    it 'sends a drift warning to the remote writes page' do
      FactoryBot.create(:ops_remote_write, base_url: Shell::APITarget.configured_url)
      method, path, = primary_action(inbox_item('drift_v0'))
      expect([method, path]).to eq([:get, remote_writes_path])

      get(path)
      expect(response).to have_http_status(:success)
    end
  end
end
