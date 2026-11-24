# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Maintenance operation runs' do
  include AdminSignInHelpers
  include ActiveJob::TestHelper

  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:, cancelled: false) }
  let(:calendar) { FactoryBot.create(:calendar, season:, meeting:, cancelled: false) }
  let(:finding) do
    FactoryBot.create(:ops_health_finding, season_id: season.id, subject_id: meeting.id,
                                           payload: { 'cancel' => { 'meeting_id' => meeting.id, 'calendar_id' => calendar.id },
                                                      'title_args' => { 'id' => meeting.id, 'date' => '-', 'description' => 'x' } })
  end

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(Outbox).to receive(:data_root).and_return(data_root)
    stub_const('Maintenance::Executor::TMP_DIR', data_root.join('tmp'))
    allow(Drift::Gate).to receive(:check) { |scope:, acknowledged: false, **| maintenance_gate_result(:ok, acknowledged:).with(scope:) }
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def page_body = response.parsed_body

  # POSTs the meeting.set_cancelled form of +finding+; returns the queued preview run.
  def request_preview(params = { meeting_id: meeting.id, calendar_id: calendar.id })
    post(operation_runs_path(key: 'meeting.set_cancelled'), params: { operation: params, finding_id: finding.id })
    Ops::OperationRun.previews.last
  end

  # A performed (succeeded) dry run.
  def performed_preview
    run = request_preview
    perform_enqueued_jobs(only: Maintenance::RunJob)
    run.reload
  end

  describe 'POST /operations/:key/runs (dry run)' do
    it 'creates the queued preview run linked to the finding and enqueues it on the maintenance worker' do
      run = nil
      expect { run = request_preview }.to have_enqueued_job(Maintenance::RunJob).on_queue('maintenance').with(run_id: kind_of(Integer), mode: 'preview')
      expect(response).to redirect_to(maintenance_run_path(run))
      expect(run).to have_attributes(operation_key: 'meeting.set_cancelled', mode: 'preview', status: 'queued', origin: 'health',
                                     health_finding_id: finding.id, season_id: season.id, started_by: admin_user.id,
                                     params: { 'meeting_id' => meeting.id, 'calendar_id' => calendar.id })
      expect(Drift::Gate).not_to have_received(:check)
    end

    it 're-renders the form with the errors of invalid params (no run)' do
      post(operation_runs_path(key: 'badge.merge'), params: { operation: { source_id: 3, force: '0' } })
      expect(response).to have_http_status(:unprocessable_content)
      expect(page_body.at_css('#operation-form-errors').text).to include(I18n.t('maintenance.errors.invalid_flag'))
      expect(Ops::OperationRun.count).to eq(0)
    end

    it 'is refused while a DB restore is in progress and when the operations are disabled' do
      # (phase 14's request guard answers first while a restore holds the lock; this is the second layer)
      allow(DbRestore::Lock).to receive(:active?).and_return(true)
      expect { request_preview }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to eq(I18n.t('maintenance.errors.restore'))

      allow(DbRestore::Lock).to receive(:active?).and_return(false)
      Ops::Setting.store!(Maintenance::ENABLED_SETTING, false)
      expect { request_preview }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to eq(I18n.t('maintenance.errors.disabled'))
    end
  end

  describe 'GET /operations/runs/:id' do
    it 'shows the dry run (facts, SQL, digest) and the one-click apply form, without writing anything' do # rubocop:disable RSpec/MultipleExpectations
      run = performed_preview
      expect(run).to be_appliable
      get(maintenance_run_path(run))
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#operation-run-sql pre').text).to include('UPDATE `meetings`', 'UPDATE `calendars`')
      expect(page_body.at_css('#operation-run-outcome').text).to include(I18n.t('maintenance.run.ready'))
      form = page_body.at_css('#frm-operation-apply')
      expect(form['action']).to eq(apply_maintenance_run_path(run))
      expect(form.at_css('input[name="typed_token"]')).to be_nil
      expect(page_body.at_css('#operation-run-finding a')['href']).to eq(health_finding_path(finding))
      expect([meeting.reload.cancelled, calendar.reload.cancelled]).to eq([false, false])
      expect(Ops::SqlScript.count).to eq(0)
    end

    it 'polls while the run is pending (status frame without src)' do
      run = request_preview
      get(maintenance_run_path(run))
      expect(page_body.at_css('turbo-frame#operation-run-status')['src']).to eq(maintenance_run_status_path(run))
      expect(page_body.at_css('[data-live-busy="true"]')).to be_present
      get(maintenance_run_status_path(run))
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('turbo-frame#operation-run-status')['src']).to be_nil
    end

    it 'shows the blocked dry run of a meeting with results, without an apply form' do
      health_add_mir(meeting)
      run = performed_preview
      get(maintenance_run_path(run))
      expect(page_body.at_css('#operation-run-errors').text).to include(I18n.t('maintenance.operations.meeting_set_cancelled.errors.has_results'))
      expect(page_body.at_css('#frm-operation-apply')).to be_nil
    end
  end

  describe 'POST /operations/runs/:id/apply' do
    it 'queues the apply after the click; the job flags the rows, registers one Outbox script and re-runs the health group' do # rubocop:disable RSpec/MultipleExpectations
      allow(LocalDb::SqlRunner).to receive(:call) { |path:| maintenance_inline_sql_runner.call(path:) }
      preview = performed_preview
      expect { post(apply_maintenance_run_path(preview)) }.to have_enqueued_job(Maintenance::RunJob).with(run_id: kind_of(Integer), mode: 'apply')
      apply = Ops::OperationRun.applies.sole
      expect(response).to redirect_to(maintenance_run_path(apply))
      expect(apply).to have_attributes(parent_run_id: preview.id, status: 'queued', health_finding_id: finding.id, started_by: admin_user.id)

      perform_enqueued_jobs(only: Maintenance::RunJob)
      expect(apply.reload).to have_attributes(status: 'succeeded', applied_locally: true)
      expect([meeting.reload.cancelled, calendar.reload.cancelled]).to eq([true, true])
      script = Ops::SqlScript.sole
      expect(script).to have_attributes(kind: 'cancel_flag', folder: 'misc', state: 'pending', applied_locally: true)
      expect(Ops::HealthRun.for_season(season.id).pending.pluck(:group_key, :trigger)).to eq([%w[meetings after_operation]])
      expect(finding.reload.mitigation_run_id).to eq(apply.id)

      follow_redirect!
      expect(page_body.at_css('#operation-run-outbox-link')['href']).to eq(outbox_path(focus: script.filename))
      expect(page_body.at_css('#operation-run-health')).to be_present
    end

    it 'refuses a second apply of the same dry run' do
      preview = performed_preview
      post(apply_maintenance_run_path(preview))
      expect { post(apply_maintenance_run_path(preview)) }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to eq(I18n.t('maintenance.apply.errors.already_applied'))
    end

    it 'needs the DB sync tick on a warning and refuses a red verdict' do
      preview = performed_preview
      allow(Drift::Gate).to receive(:check) { |scope:, acknowledged: false, **| maintenance_gate_result(:warn, acknowledged:).with(scope:) }
      expect { post(apply_maintenance_run_path(preview)) }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to start_with(I18n.t('maintenance.apply.errors.drift', summary: '').strip)
      expect { post(apply_maintenance_run_path(preview), params: { drift_ack: '1' }) }.to have_enqueued_job(Maintenance::RunJob)
      expect(Ops::OperationRun.applies.sole.drift_ack).to be(true)

      other = performed_preview
      allow(Drift::Gate).to receive(:check) { |scope:, acknowledged: false, **| maintenance_gate_result(:block, acknowledged:).with(scope:) }
      expect { post(apply_maintenance_run_path(other), params: { drift_ack: '1' }) }.not_to have_enqueued_job(Maintenance::RunJob)
    end

    it 'needs the exact typed text for a typed confirmation' do
      preview = FactoryBot.create(:ops_operation_run, :previewed, operation_key: 'swimmer.merge', params: { 'source_id' => 1, 'dest_id' => 2 },
                                                                  summary: { 'confirmation' => 'typed', 'typed_token' => 'MERGE 1 INTO 2' })
      get(maintenance_run_path(preview))
      expect(page_body.at_css('#frm-operation-apply input[name="typed_token"]')).to be_present
      expect { post(apply_maintenance_run_path(preview), params: { typed_token: 'MERGE 2 INTO 1' }) }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to eq(I18n.t('maintenance.apply.errors.typed_token'))
      expect { post(apply_maintenance_run_path(preview), params: { typed_token: 'MERGE 1 INTO 2' }) }.to have_enqueued_job(Maintenance::RunJob)
    end

    it 'refuses a dry run that cannot be applied' do
      preview = FactoryBot.create(:ops_operation_run, :previewed, error_messages: ['broken'])
      expect { post(apply_maintenance_run_path(preview)) }.not_to have_enqueued_job(Maintenance::RunJob)
      expect(flash[:error]).to eq(I18n.t('maintenance.apply.errors.not_appliable'))
    end
  end

  describe 'an interrupted apply (worker killed)' do
    # A preview and its apply left 'running' by a dead worker (its Solid Queue job failed after the process was pruned).
    def interrupted_apply
      preview = performed_preview
      post(apply_maintenance_run_path(preview))
      apply = Ops::OperationRun.applies.sole
      apply.update_columns(status: 'running', started_at: 5.minutes.ago, job_id: 'dead-job') # rubocop:disable Rails/SkipsModelValidations
      allow(Maintenance::JobState).to receive(:for).and_call_original
      allow(Maintenance::JobState).to receive(:for).with('dead-job').and_return(:dead)
      clear_enqueued_jobs
      [preview, apply]
    end

    it 'shows the warning that the local DB may already contain the change, stops polling and offers a new dry run' do
      _preview, apply = interrupted_apply
      FileUtils.mkdir_p(data_root.join('tmp'))
      File.write(data_root.join('tmp', "#{apply.id}.sql"), 'UPDATE x;')
      get(maintenance_run_path(apply))
      expect(page_body.at_css('#operation-run-state').text.strip).to eq(I18n.t('maintenance.statuses.interrupted'))
      expect(page_body.at_css('#operation-run-outcome').text).to include(I18n.t('maintenance.run.interrupted_running').split(':').first)
      expect(page_body.at_css('#operation-run-tmp-script')).to be_present
      expect(page_body.at_css('#operation-run-new-dry-run')['href'])
        .to eq(new_operation_path(key: 'meeting.set_cancelled', finding_id: finding.id))
      expect(page_body.at_css('[data-live-busy="true"]')).to be_nil
      expect(enqueued_jobs).to be_empty
      expect(Ops::SqlScript.count).to eq(0)
    end

    it 'keeps its own dry run consumed (no second apply) but never blocks a new dry run and its apply' do
      preview, apply = interrupted_apply
      get(maintenance_run_path(preview))
      expect(page_body.at_css('#operation-apply-interrupted a')['href']).to eq(maintenance_run_path(apply))
      expect(page_body.at_css('#frm-operation-apply')).to be_nil
      expect { post(apply_maintenance_run_path(preview)) }.not_to have_enqueued_job(Maintenance::RunJob)

      fresh = performed_preview
      expect(fresh.warning_list).to eq([I18n.t('maintenance.executor.interrupted_apply', id: apply.id)])
      expect(fresh).to be_appliable
      expect { post(apply_maintenance_run_path(fresh)) }.to have_enqueued_job(Maintenance::RunJob).with(run_id: kind_of(Integer), mode: 'apply')
      expect(apply.reload.status).to eq('running') # (never re-run, finished nor registered by itself)
    end
  end
end
