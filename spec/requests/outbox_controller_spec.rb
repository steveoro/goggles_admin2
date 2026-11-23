# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OutboxController do
  include AdminSignInHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:season_id) { SeasonDefaults.default_season_id }

  before(:each) do
    allow(Outbox).to receive(:data_root).and_return(data_root)
    allow(Outbox::RemoteStatusJob).to receive(:perform_later)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def script(rel_path, **attributes)
    create_sql_script(data_root, rel_path, **attributes)
  end

  def page
    response.parsed_body
  end

  it 'redirects an unlogged user to the sign-in page' do
    get outbox_path
    expect(response).to redirect_to(new_user_session_path)
  end

  context 'with a signed-in admin' do
    before(:each) { sign_in_admin(admin_user) }

    describe 'GET /outbox' do
      it 'lists every pending script, whatever the folder, while the other sections keep the default filter' do
        script("results.new/#{season_id}/0010-a-lt4.sql")
        script('results.new/misc/0011-merge_teams-1-2.sql')
        script('results.new/999/0012-team_manager-1-2.sql')
        script('results.sent/999/0005-old-lt4.sql', state: 'sent', remote_iq_id: 3)
        script("results.sent/#{season_id}/0004-seen-lt4.sql", state: 'sent', remote_iq_id: 2)

        get outbox_path
        expect(response).to have_http_status(:success)
        rows = page.css('#outbox-needs-push-table tbody tr').pluck('data-outbox-filename')
        expect(rows).to eq(%w[0010-a-lt4.sql 0011-merge_teams-1-2.sql 0012-team_manager-1-2.sql])
        expect(page.css('#outbox-on-server-table tbody tr').pluck('data-outbox-filename')).to eq(['0004-seen-lt4.sql'])

        get outbox_path(folder: 'all')
        expect(page.css('#outbox-on-server-table tbody tr').size).to eq(2)
      end

      it 'adopts a file dropped by hand on load' do
        write_sql_file(data_root, "results.new/#{season_id}/0020-merge_badges-1-2.sql")
        get outbox_path
        expect(page.at_css("#outbox-needs-push-table tr[data-outbox-filename='0020-merge_badges-1-2.sql']")).to be_present
      end

      it 'highlights the focused row and marks the blocked ones' do
        script("results.new/#{season_id}/0010-a-lt4.sql")
        later = script("results.new/#{season_id}/0011-b-lt4.sql")
        get outbox_path(focus: '0011-b-lt4.sql')
        row = page.at_css("#outbox-script-#{later.id}")
        expect(row['data-outbox-focus']).to eq('true')
        expect(row['class']).to include('table-warning')
        expect(row.text).to include(I18n.t('outbox.blocked_by', file: '0010-a-lt4.sql'))
      end

      it 'renders the frame alone for the live refresh' do
        get outbox_path(frame: 1)
        expect(page.at_css('turbo-frame#outbox-scripts')).to be_present
        expect(response.body).not_to include('<html')
      end

      it 'shows the setup notice and the disk list when the ops DB is not available' do
        write_sql_file(data_root, "results.new/#{season_id}/0020-merge_badges-1-2.sql")
        allow(Ops::Database).to receive(:state).and_return(:missing)
        get outbox_path
        expect(response).to have_http_status(:success)
        expect(page.at_css('#outbox-ops-missing')).to be_present
        expect(page.at_css('#outbox-disk-list').text).to include("results.new/#{season_id}/0020-merge_badges-1-2.sql")
      end
    end

    it 'GET /push/index redirects to the Outbox' do
      get '/push/index'
      expect(response).to redirect_to(outbox_path)
    end

    it 'GET /outbox/:id shows the script with its SQL preview' do
      row = script('results.new/misc/0011-merge_teams-1-2.sql', content: "UPDATE teams SET x=1;\r\n")
      get outbox_script_path(row)
      expect(response).to have_http_status(:success)
      expect(page.at_css('#outbox-script-preview').text).to include('UPDATE teams SET x=1;')
      expect(page.at_css('#btn-outbox-push-this')['href']).to eq(new_outbox_push_path(ids: [row.id]))
    end

    describe 'operator actions' do
      let(:row) { script('results.new/misc/0011-merge_teams-1-2.sql') }

      it 'holds and releases a script' do
        post hold_outbox_script_path(row)
        expect(row.reload).to be_held
        post release_outbox_script_path(row)
        expect(row.reload).to be_pending
      end

      it 'refuses to release a script not applied locally without the explicit choice' do
        row.update!(state: 'held', held_reason: 'not_applied_locally', applied_locally: false)
        post release_outbox_script_path(row)
        expect(flash[:alert]).to be_present
        expect(row.reload).to be_held
        post release_outbox_script_path(row, force: 1)
        expect(row.reload).to be_pending
      end

      it 'applies a held script locally (stubbed client) and makes it pending' do
        row.update!(state: 'held', held_reason: 'not_applied_locally', applied_locally: false)
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        allow(Open3).to receive(:capture3).and_return(['', '', status])
        post apply_locally_outbox_script_path(row)
        expect(row.reload).to have_attributes(state: 'pending', applied_locally: true)
        expect(Ops::Event.last.kind).to eq('outbox.applied_locally')
      end

      it 'discards a script with a note, moving its file out of the scan roots' do
        post discard_outbox_script_path(row), params: { note: '' }
        expect(row.reload).to be_pending
        post discard_outbox_script_path(row), params: { note: 'duplicate of 0010' }
        expect(row.reload).to have_attributes(state: 'discarded', rel_path: 'results.new/discarded/misc/0011-merge_teams-1-2.sql')
        expect(data_root.join('results.new/discarded/misc/0011-merge_teams-1-2.sql')).to exist
      end

      it 'resolves an in-doubt push as sent with the remote id' do
        row.update!(state: 'in_doubt', target_api_url: 'http://localhost:8081', target_env: 'unknown')
        post resolve_outbox_script_path(row), params: { to: 'sent', remote_iq_id: 812 }
        expect(row.reload).to have_attributes(state: 'sent', remote_iq_id: 812, rel_path: 'results.sent/misc/0011-merge_teams-1-2.sql')
      end
    end

    describe 'push' do
      let!(:first) { script("results.new/#{season_id}/0010-a-lt4.sql") }
      let!(:second) { script('results.new/misc/0011-merge_teams-1-2.sql') }
      let(:ping) { APIProxy::Result.new(DummyResponse.new(body: { msg: 'OK', version: '7.0.1' }.to_json)) }

      before(:each) { allow(APIProxy).to receive(:ping).and_return(ping) }

      it 'GET /outbox/push/new shows the ordered list, the target, the unverified environment and the typed label' do
        get new_outbox_push_path(scope: 'all_pending')
        expect(response).to have_http_status(:success)
        expect(page.css('#outbox-push-list li').map { |li| li['data-outbox-script-id'].to_i }).to eq([first.id, second.id])
        expect(page.at_css('#outbox-push-environment').text).to include(I18n.t('outbox.push.unverified'))
        expect(page.at_css('#outbox-push-reachability').text).to include('7.0.1')
        expect(page.at_css('input#confirm_label')).to be_present
      end

      it 'warns about a lower pending script for a single push and offers the override' do
        get new_outbox_push_path(ids: [second.id])
        expect(page.at_css('#outbox-push-blockers').text).to include('0010-a-lt4.sql')
      end

      it 'refuses a push without the confirmation' do
        expect { post outbox_push_path, params: { scope: 'all_pending' } }.not_to change(Ops::PushRun, :count)
        expect(response).to redirect_to(new_outbox_push_path(scope: 'all_pending'))
      end

      it 'refuses an unverified target without the typed environment label' do
        expect do
          post outbox_push_path, params: { confirmed: '1', ids: [first.id, second.id], confirm_label: 'nope' }
        end.not_to change(Ops::PushRun, :count)
        expect(flash[:alert]).to eq(I18n.t('outbox.flash.label_mismatch'))
      end

      it 'refuses to jump a lower pending script unless overridden' do
        post outbox_push_path, params: { confirmed: '1', ids: [second.id], confirm_label: 'unknown' }
        expect(flash[:alert]).to eq(I18n.t('outbox.flash.blocked'))
        expect(Ops::PushRun.count).to eq(0)
      end

      it 'creates the run and enqueues the push job after the confirmation (DB sync warning ticked)' do
        allow(Outbox::Pusher).to receive(:jwt_valid?).and_return(true)
        expect do
          post outbox_push_path, params: { confirmed: '1', scope: 'all_pending', confirm_label: 'unknown', drift_ack: '1' }
        end.to have_enqueued_job(Outbox::PushJob)
        run = Ops::PushRun.last
        expect(run).to have_attributes(status: 'running', user_id: admin_user.id, script_ids: [first.id, second.id],
                                       target_env: 'unknown', override_order: false, drift_acknowledged: true)
        expect(response).to redirect_to(outbox_path(run: run.id))
      end

      describe 'the DB sync gate (scope :push) and the API-reported environment (phase 08)' do
        let(:api_url) { Shell::APITarget.configured_url }
        let(:verified_ping) do
          body = { msg: 'OK', version: '7.3', environment: 'production', capabilities: %w[iq_batch_outcome] }
          APIProxy::Result.new(DummyResponse.new(body: body.to_json))
        end

        before(:each) { allow(Outbox::Pusher).to receive(:jwt_valid?).and_return(true) }

        it "shows the 'unknown' verdict (API without fingerprints) with the tick on the confirmation page" do
          get new_outbox_push_path(scope: 'all_pending')
          expect(page.at_css('#outbox-push-db-sync')['data-gate-level']).to eq('warn')
          expect(page.at_css('#outbox-push-db-sync #drift-indicator')['data-drift-verdict']).to eq('unknown')
          expect(page.at_css('#outbox-push-drift input#drift_ack[required]')).to be_present
          expect(Ops::DbFingerprint.last).to have_attributes(trigger: 'gate', mode: 'light', verdict: 'unknown')
        end

        it 'refuses the push without the tick when the gate warns' do
          expect do
            post outbox_push_path, params: { confirmed: '1', scope: 'all_pending', confirm_label: 'unknown' }
          end.not_to change(Ops::PushRun, :count)
          expect(response).to redirect_to(new_outbox_push_path(scope: 'all_pending'))
          expect(flash[:alert]).to start_with(I18n.t('db_sync.gate.summary', verdict: I18n.t('db_sync.verdicts.unknown')))
        end

        it 'warns on a red verdict (never blocks a push) and pushes with the tick' do
          FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: api_url)
          get new_outbox_push_path(scope: 'all_pending')
          expect(page.at_css('#outbox-push-drift').text).to include(I18n.t('outbox.push.drift_red').first(30))
          expect do
            post outbox_push_path, params: { confirmed: '1', scope: 'all_pending', confirm_label: 'unknown', drift_ack: '1' }
          end.to have_enqueued_job(Outbox::PushJob)
        end

        it 'needs neither the tick nor the typed label on a green verdict against a production API that says so' do
          allow(APIProxy).to receive(:ping).and_return(verified_ping)
          FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url)
          get new_outbox_push_path(scope: 'all_pending')
          expect(page.at_css('#outbox-push-environment').text).to include('production', I18n.t('outbox.push.verified'))
          expect(page.at_css('input#confirm_label')).to be_nil
          expect(page.at_css('#outbox-push-drift')).to be_nil
          expect(SystemStatus::APISnapshot.read(api_url).payload).to include('environment' => 'production')

          expect { post outbox_push_path, params: { confirmed: '1', scope: 'all_pending' } }.to have_enqueued_job(Outbox::PushJob)
          expect(Ops::PushRun.last).to have_attributes(target_env: 'production', drift_acknowledged: false)
        end
      end

      it 'refuses a second run while one is live' do
        allow(Outbox::Pusher).to receive(:jwt_valid?).and_return(true)
        Ops::PushRun.create!(status: 'running', script_ids: [first.id], started_at: Time.current)
        expect do
          post outbox_push_path, params: { confirmed: '1', scope: 'all_pending', confirm_label: 'unknown' }
        end.not_to have_enqueued_job(Outbox::PushJob)
        expect(flash[:alert]).to eq(I18n.t('outbox.flash.run_in_progress'))
      end
    end

    describe 'remote actions on a failed script (phase 08)' do
      let(:api_url) { 'http://localhost:8081' }
      let!(:failed) do
        script('results.new/misc/0011-merge_teams-1-2.sql', state: 'failed', remote_iq_id: 9123, target_api_url: api_url,
                                                            target_env: 'production', remote_error: 'ERROR 1062 (23000)')
      end
      let!(:later) do
        script('results.sent/misc/0012-merge_teams-3-4.sql', state: 'sent', remote_iq_id: 9124, target_api_url: api_url,
                                                             target_env: 'production')
      end

      def json_answer(body)
        APIProxy::Result.new(DummyResponse.new(body: body.to_json))
      end

      before(:each) do
        body = { msg: 'OK', environment: 'production', capabilities: %w[iq_batch_outcome] }
        SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
        allow(Outbox::Pusher).to receive(:jwt_valid?).and_return(true)
      end

      it 'shows the server error, Retry, Withdraw and the discard form on the script page' do
        get outbox_script_path(failed)
        expect(page.at_css('#outbox-script-remote-error').text).to include('ERROR 1062')
        expect(page.at_css('#btn-outbox-retry')).to be_present
        expect(page.at_css('#btn-outbox-withdraw').text).to include('2')
        expect(page.at_css('#frm-outbox-abandon')).to be_present
      end

      it 'marks the later queued scripts "blocked by #0011" in the Outbox' do
        get outbox_path(folder: 'all')
        expect(page.at_css('#outbox-failed-alert')).to be_present
        expect(page.at_css("#outbox-script-#{later.id} .outbox-server-blocked").text).to include('#0011')
      end

      it 'retries an unchanged failed script in place' do
        allow(APIProxy).to receive(:call).and_return(json_answer(true))
        post retry_outbox_script_path(failed)
        expect(APIProxy).to have_received(:call)
          .with(hash_including(method: :put, url: 'import_queue/9123', payload: { error_messages: '', process_runs: 0 }))
        expect(failed.reload).to have_attributes(state: 'sent', rel_path: 'results.sent/misc/0011-merge_teams-1-2.sql')
        expect(flash[:notice]).to eq(I18n.t('outbox.flash.retried', file: failed.filename))
      end

      it 'withdraws the failed script and the later queued one (highest seq first), back to pending' do
        calls = []
        allow(APIProxy).to receive(:call) do |options|
          calls << [options[:method], options[:url]]
          options[:method] == :get ? json_answer('id' => 1, 'done' => false, 'process_runs' => 0) : json_answer(true)
        end
        post withdraw_outbox_script_path(failed)
        expect(calls).to eq([[:get, 'import_queue/9124'], [:delete, 'import_queue/9124'], [:get, 'import_queue/9123'],
                             [:delete, 'import_queue/9123']])
        expect([failed.reload.state, later.reload.state]).to eq(%w[pending pending])
        expect(later.rel_path).to eq('results.new/misc/0012-merge_teams-3-4.sql')
        expect(flash[:notice]).to eq(I18n.t('outbox.flash.withdrawn', file: failed.filename, count: 2))
      end

      it 'refuses the remote actions with an expired API session' do
        allow(Outbox::Pusher).to receive(:jwt_valid?).and_return(false)
        allow(APIProxy).to receive(:call)
        post retry_outbox_script_path(failed)
        expect(flash[:alert]).to eq(I18n.t('outbox.flash.jwt_invalid'))
        expect(APIProxy).not_to have_received(:call)
      end
    end
  end
end
