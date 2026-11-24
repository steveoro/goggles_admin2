# frozen_string_literal: true

require 'rails_helper'

# Phase 14, step 2: while a guided DB restore holds the lock every page answers from the ops DB only (DbRestoreGuard,
# restore layout, 503), and the progress page works without MySQL for a local request with the run's token.
RSpec.describe 'DB restore guard' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }

  after(:each) { Ops::Database.reset_state! }

  # Makes every MySQL access of the primary pool raise (as while the database is dropped).
  def disconnect_mysql!
    pool = ActiveRecord::Base.connection_pool
    %i[lease_connection with_connection checkout].each do |method|
      allow(pool).to receive(method).and_raise(ActiveRecord::ConnectionNotEstablished, 'MySQL is gone (spec)')
    end
  end

  describe 'without a restore in progress' do
    it 'lets the requests through' do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
      get(settings_path)
      expect(response).to have_http_status(:success)
    end
  end

  describe 'while a run holds the lock' do
    let(:run) { lock_with_run(status: 'loading', progress_bytes: 500) }

    before(:each) do
      # (A first request materializes the test sign-in, whose Devise trackable hook writes MySQL; the operator of a
      #  real restore is already signed in.)
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
      get(settings_path)
      run
    end

    it 'answers 503 with the restore page for a sample of HTML pages, without touching MySQL' do
      disconnect_mysql!
      [root_path, settings_path, outbox_path, db_sync_path, season_board_path, health_path, api_meetings_path,
       new_user_session_path].each do |path|
        get(path)
        expect(response).to have_http_status(:service_unavailable), path
        expect(response.parsed_body.at_css('#db-restore-locked')['data-run-id']).to eq(run.id.to_s), path
      end
    end

    it 'answers 503 JSON to the other formats' do
      disconnect_mysql!
      get('/lookup/swimmers', headers: { 'Accept' => 'application/json' })
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include('error' => 'db_restore_in_progress', 'run_id' => run.id)
    end

    it 'refuses the POSTs that enqueue click-only jobs (Outbox push, Data-Fix commit)' do
      post(outbox_push_path, params: { confirmed: '1' })
      expect(response).to have_http_status(:service_unavailable)
      post(commit_phase6_path(file_path: 'crawler/data/results.new/242/x.json'))
      expect(response).to have_http_status(:service_unavailable)
      expect(Ops::PushRun.count).to eq(0)
      expect(Ops::CommitReport.count).to eq(0)
    end

    it 'links the progress page from the browser that confirmed the run' do
      token = run.issue_token!
      get(db_restore_path(run, token:))
      expect(response).to have_http_status(:success)
      get(root_path)
      expect(response.parsed_body.at_css('#btn-db-restore-progress')['href']).to eq(db_restore_path(run))
    end

    describe 'the progress page' do
      let(:token) { run.issue_token! }

      before(:each) { token }

      it 'renders with the MySQL primary disconnected (token in the URL), and its status JSON too' do
        disconnect_mysql!
        get(db_restore_path(run, token:))
        expect(response).to have_http_status(:success)
        page = response.parsed_body
        expect(page.at_css('#db-restore-progress')['data-db-restore-status-value']).to eq('loading')
        expect(page.at_css('#db-restore-layout')).to be_present
        get(db_restore_status_path(run, format: :json))
        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include('status' => 'loading', 'progress_bytes' => 500, 'dump_bytes' => 1_000, 'percent' => 50.0)
      end

      it 'refuses a wrong or missing token' do
        get(db_restore_path(run, token: 'wrong'))
        expect(response).to have_http_status(:forbidden)
        get(db_restore_status_path(run, format: :json))
        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses a non-local request, even with the token' do
        get(db_restore_path(run, token:), headers: { 'REMOTE_ADDR' => '10.1.2.3' })
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.at_css('#db-restore-refused')).to be_present
      end
    end
  end

  describe 'after a restore (db_epoch bumped)' do
    it 'disconnects the MySQL pool once in the next request' do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
      get(settings_path)
      pool = ActiveRecord::Base.connection_pool
      allow(pool).to receive(:disconnect!)
      Ops::Setting.store!(Ops::Setting::DB_EPOCH_KEY, Ops::Setting.db_epoch + 1)
      get(settings_path)
      get(settings_path)
      expect(pool).to have_received(:disconnect!).once
    end
  end
end
