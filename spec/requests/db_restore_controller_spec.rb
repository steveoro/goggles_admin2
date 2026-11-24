# frozen_string_literal: true

require 'rails_helper'

# The guided restore wizard (phase 14) end to end, with the target guards, the queues and the Data-Fix sessions
# stubbed (the test env is not 'development') and every job enqueued, never run against MySQL.
RSpec.describe DbRestoreController do
  include AdminSignInHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { prepare_admin_user }
  let(:dump_dir) { Pathname.new(Dir.mktmpdir) }
  let(:dump_path) do
    path = dump_dir.join('production-0430-backup.sql.bz2')
    FileUtils.cp(Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2'), path)
    path.to_s
  end
  let(:target) { passing_target(database: DbRestore::Target.current.database) }
  let(:queues) { DbRestoreHelpers::FakeQueues.new }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
    allow(DbRestore::DumpCatalog).to receive(:default_dirs).and_return([dump_dir.to_s])
    allow(DbRestore::Target).to receive(:current).and_return(target)
    allow(DbRestore::Queues).to receive(:new).and_return(queues)
    allow(DataFix::SessionIndex).to receive(:new).and_return(empty_session_index)
    dump_path
  end

  after(:each) do
    FileUtils.rm_rf(dump_dir)
    Ops::Database.reset_state!
  end

  def last_run
    Ops::RestoreRun.order(:id).last
  end

  # A run inspected (InspectJob performed inline) with the snapshot skipped.
  def ready_run
    post(db_restores_path, params: { dump: dump_path })
    perform_enqueued_jobs(only: DbRestore::InspectJob)
    run = last_run
    post(snapshot_db_restore_path(run), params: { skip: '1' })
    run.reload
  end

  describe 'GET /db_restore/new' do
    it 'shows the preconditions, the production dumps and the history' do
      create_restore_run(status: 'finished', finished_at: 1.day.ago)
      get(new_db_restore_path)
      expect(response).to have_http_status(:success)
      page = response.parsed_body
      expect(page.css('#db-restore-checks [data-check]').pluck('data-level').uniq).to eq(['ok'])
      expect(page.css('#db-restore-dumps input[name=dump]').pluck('value')).to eq([dump_path])
      expect(page.at_css('#btn-db-restore-inspect')['disabled']).to be_nil
      expect(page.css('#db-restore-history tbody tr').size).to eq(1)
    end

    it 'disables the wizard when a guard refuses (the test environment is not development)' do
      allow(DbRestore::Target).to receive(:current).and_call_original
      get(new_db_restore_path)
      page = response.parsed_body
      expect(page.at_css('#db-restore-checks [data-check=environment]')['data-level']).to eq('refused')
      expect(page.at_css('#btn-db-restore-inspect')['disabled']).to eq('disabled')
    end

    it 'maps to the contextual DB restore item under DB sync' do
      item = Shell::Navigation.item_for('db_restore', 'new')
      expect(item.key).to eq(:db_restore)
      expect(Shell::Navigation.breadcrumbs_for('db_restore', 'new').map(&:first))
        .to eq([I18n.t('shell.groups.data_quality'), I18n.t('db_sync.nav'), I18n.t('db_restore.nav')])
    end
  end

  describe 'POST /db_restore' do
    it 'refuses a dump outside the catalog' do
      post(db_restores_path, params: { dump: '/etc/hosts' })
      expect(response).to redirect_to(new_db_restore_path)
      expect(Ops::RestoreRun.count).to eq(0)
    end

    it 'refuses while a precondition fails' do
      Ops::SqlScript.create!(seq: 970_001, rel_path: 'results.new/misc/0970-x.sql', filename: '0970-x.sql', folder: 'misc', kind: 'manual',
                             sha256: 'c' * 64, state: 'pending')
      post(db_restores_path, params: { dump: dump_path })
      expect(response).to redirect_to(new_db_restore_path)
      expect(flash[:alert]).to include(I18n.t('db_restore.checks.outbox.refused', detail: '1'))
      expect(Ops::RestoreRun.count).to eq(0)
    end

    it 'creates an inspecting run and enqueues the inspection, which makes it ready' do
      expect { post(db_restores_path, params: { dump: dump_path }) }.to have_enqueued_job(DbRestore::InspectJob)
      run = last_run
      expect(run).to have_attributes(status: 'inspecting', dump_path:, user_id: admin_user.id, target_database: target.database)
      expect(response).to redirect_to(inspect_db_restore_path(run))
      perform_enqueued_jobs(only: DbRestore::InspectJob)
      expect(run.reload).to have_attributes(status: 'ready', dump_iq_next_id: 9124, dump_schema_version: '20261027120100')
      get(inspect_db_restore_path(run))
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at_css('#db-restore-schema').text).to include('20261027120100')
      expect(response.parsed_body.at_css('#btn-db-restore-snapshot')).to be_present
    end
  end

  describe 'the safety snapshot' do
    it 'enqueues the snapshot job' do
      post(db_restores_path, params: { dump: dump_path })
      perform_enqueued_jobs(only: DbRestore::InspectJob)
      run = last_run
      expect { post(snapshot_db_restore_path(run)) }.to have_enqueued_job(DbRestore::SnapshotJob).with(run_id: run.id)
      expect(run.reload).to be_snapshotting
      get(inspect_db_restore_path(run, format: :json))
      expect(response.parsed_body).to include('status' => 'snapshotting')
    end

    it 'can be skipped with a tick, opening the confirmation' do
      run = ready_run
      expect(run.ticked?(:skip_snapshot)).to be(true)
      expect(response).to redirect_to(confirmation_db_restore_path(run))
      get(confirmation_db_restore_path(run))
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at_css('#db-restore-terminal-preview').text).to include('db:rebuild from=production-0430-backup to=development')
    end
  end

  describe 'POST /db_restore/:id/confirm' do
    it 'refuses a wrong typed name (no lock, no job)' do
      run = ready_run
      post(confirm_db_restore_path(run), params: { typed_name: 'goggles' })
      expect(response).to redirect_to(confirmation_db_restore_path(run))
      expect(DbRestore::Lock.active?).to be(false)
      expect(enqueued_jobs.pluck('job_class')).not_to include('DbRestore::RestoreJob')
    end

    it 'takes the lock, pauses the queues, grants this browser the progress page and enqueues the load' do # rubocop:disable RSpec/MultipleExpectations
      run = ready_run
      expect do
        post(confirm_db_restore_path(run), params: { typed_name: target.database, api_url_choice: 'keep' })
      end.to have_enqueued_job(DbRestore::RestoreJob).with(run_id: run.id, mode: 'load')
      token = Rack::Utils.parse_query(URI(response.location).query)['token']
      expect(response).to redirect_to(db_restore_path(run, token:))
      expect(run.reload).to have_attributes(status: 'confirmed', mode: 'wizard')
      expect(run.token_matches?(token)).to be(true)
      expect(run.confirmations).to include('typed_name' => true, 'api_url_choice' => 'keep', 'confirmed_by' => admin_user.id)
      expect(DbRestore::Lock.current_run).to eq(run)
      expect(queues.paused).to eq(DbRestore::PAUSED_QUEUES)
      expect(run.preserved['paused_queues']).to eq(DbRestore::PAUSED_QUEUES)
      get(db_restore_path(run))
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at_css('#db-restore-layout')).to be_present
      get(root_path)
      expect(response).to have_http_status(:service_unavailable)
    end

    it 'keeps only the run id and an expiry in the session (never the token)' do
      run = ready_run
      post(confirm_db_restore_path(run), params: { typed_name: target.database })
      token = Rack::Utils.parse_query(URI(response.location).query)['token']
      expect(session[DbRestoreGuard::SESSION_KEY].keys).to contain_exactly('run_id', 'until')
      stored = Ops::ApplicationRecord.with_connection { |conn| conn.select_values('SELECT data FROM sessions') }.join
      expect(stored).not_to include(token)
      get(db_restore_path(run, token:))
      expect(response.parsed_body.at_css('#db-restore-progress-url').text).to include("token=#{token}")
      get(db_restore_path(run))
      expect(response.parsed_body.at_css('#db-restore-progress-url')).to be_nil
    end

    it 'refuses the progress page without the token once the session grant expired' do
      run = ready_run
      post(confirm_db_restore_path(run), params: { typed_name: target.database })
      token = Rack::Utils.parse_query(URI(response.location).query)['token']
      travel(DbRestoreGuard::GRANT_TTL + 1.minute) do
        get(db_restore_path(run))
        expect(response).to have_http_status(:forbidden)
        get(db_restore_path(run, token:))
        expect(response).to have_http_status(:success)
      end
    end

    it 'enqueues the terminal mode' do
      run = ready_run
      expect do
        post(confirm_db_restore_path(run), params: { typed_name: target.database, load_mode: 'terminal' })
      end.to have_enqueued_job(DbRestore::RestoreJob).with(run_id: run.id, mode: 'terminal')
      expect(run.reload.mode).to eq('terminal')
    end
  end

  describe 'the progress page actions' do
    let(:run) { lock_with_run(status: 'interrupted', target_database: target.database, preserved: { 'paused_queues' => %w[default] }) }
    let(:token) { run.issue_token! }

    it 'offers resume and abandon on an interrupted run, and resumes it' do
      get(db_restore_path(run, token:))
      page = response.parsed_body
      expect(page.at_css('#btn-db-restore-resume')).to be_present
      expect(page.at_css('#btn-db-restore-load-snapshot')).to be_nil
      expect { post(resume_db_restore_path(run)) }.to have_enqueued_job(DbRestore::RestoreJob).with(run_id: run.id, mode: 'resume')
      expect(response).to redirect_to(db_restore_path(run))
    end

    it 'loads the safety snapshot when it exists' do
      run.update!(snapshot_path: dump_path)
      get(db_restore_path(run, token:))
      expect { post(load_snapshot_db_restore_path(run)) }.to have_enqueued_job(DbRestore::RestoreJob).with(run_id: run.id, mode: 'snapshot')
    end

    it 'abandons only with the typed name, releasing the lock and resuming the queues' do
      get(db_restore_path(run, token:))
      post(abandon_db_restore_path(run), params: { typed_name: 'nope' })
      expect(DbRestore::Lock.active?).to be(true)
      post(abandon_db_restore_path(run), params: { typed_name: target.database })
      expect(response).to redirect_to(db_restore_result_path(run))
      expect(run.reload).to have_attributes(status: 'cancelled', step: 'abandoned')
      expect(DbRestore::Lock.active?).to be(false)
      expect(queues.resumed).to eq(%w[default])
      expect(queues.resumed_while_locked).to eq([false])
      get(db_restore_result_path(run))
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at_css('#db-restore-result')['data-status']).to eq('cancelled')
    end

    it 'runs the post-steps after a terminal load' do
      run.update!(status: 'loading', step: Ops::RestoreRun::AWAITING_TERMINAL)
      get(db_restore_path(run, token:))
      expect(response.parsed_body.at_css('#db-restore-terminal-command').text).to include('db:rebuild')
      expect { post(post_steps_db_restore_path(run)) }.to have_enqueued_job(DbRestore::RestoreJob).with(run_id: run.id, mode: 'post_steps')
    end

    it 'refuses the actions without the token' do
      expect { post(resume_db_restore_path(run)) }.not_to have_enqueued_job(DbRestore::RestoreJob)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /db_restore/:id/result' do
    it 'shows the outcome, the pending engine migrations and the scripts newer than the dump' do
      run = create_restore_run(status: 'finished', finished_at: Time.current, started_at: 10.minutes.ago,
                               outcome: { 'loaded_from' => 'dump', 'pending_migrations' => %w[29991231000000], 'api_url' => 'kept',
                                          'jwt' => 'applied', 'staging_purged' => 4 },
                               inspection: { 'scripts_after_dump' => %w[0990-x.sql] })
      get(db_restore_result_path(run))
      page = response.parsed_body
      expect(page.at_css('#db-restore-result')['data-status']).to eq('finished')
      expect(page.at_css('#db-restore-pending-migrations').text).to include('29991231000000', 'db:migrate')
      expect(page.at_css('#db-restore-scripts-after-dump').text).to include('0990-x.sql')
    end
  end

  describe 'entry points' do
    it 'links the wizard from /db_sync and from the red DB sync inbox item' do
      get(db_sync_path)
      expect(response.parsed_body.at_css('#btn-db-sync-restore')['href']).to eq(new_db_restore_path)
      FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: APIProxy.configured_base_url.to_s.delete_suffix('/'))
      context = Inbox::Context.new(board_snapshot: nil, season: nil, api_url: APIProxy.configured_base_url.to_s.delete_suffix('/'))
      item = Drift::InboxSource.new.items(context).sole
      expect(item.secondary_action).to have_attributes(path: new_db_restore_path, label: I18n.t('inbox.drift.restore'))
    end
  end
end
