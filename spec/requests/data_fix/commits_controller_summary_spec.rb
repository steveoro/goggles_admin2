# frozen_string_literal: true

require 'rails_helper'

# Commit summary (GET data_fix/commit_summary), the guarded Commit click and the persistent report (phase 09),
# on a structure-only source (the smallest commit).
RSpec.describe DataFix::CommitsController, :data_fix_commit do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:temp_dir) { Dir.mktmpdir }
  let(:new_dir) { File.join(temp_dir, 'results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_file) { File.join(new_dir, 'summary_meeting-lt4.json') }
  let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "specsummary#{rand(100_000)}" }
  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Summary Spec Meeting', 'code' => meeting_code, 'header_year' => '2026/2027',
      'header_date' => '2026-10-24', 'edition' => 1, 'edition_type_id' => GogglesDb::EditionType::ORDINAL_ID,
      'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID, 'dateYear1' => 2026, 'dateMonth1' => 10, 'dateDay1' => 24,
      'meeting_session' => [
        { 'id' => nil, 'description' => 'Session 1', 'session_order' => 1, 'scheduled_date' => '2026-10-24',
          'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
          'swimming_pool' => { 'id' => swimming_pool.id, 'name' => swimming_pool.name, 'nick_name' => swimming_pool.nick_name,
                               'address' => swimming_pool.address, 'pool_type_id' => swimming_pool.pool_type_id,
                               'lanes_number' => swimming_pool.lanes_number, 'city_id' => swimming_pool.city_id } }
      ]
    }
  end

  def guards(level, acknowledged: false)
    DataFix::Guards::Result.new(level:, reasons: ["#{level} reason"], verdict: nil, acknowledged:)
  end

  before(:each) do
    File.write(source_file, JSON.pretty_generate('_meta' => { 'meeting_only' => true }, 'layoutType' => 4,
                                                 'meetingName' => 'Summary Spec Meeting', 'events' => []))
    PhaseFileManager.new(phase1_file).write!(data: phase1_data, meta: { 'generator' => 'spec' })
    sign_in_admin(admin_user)
  end

  after(:each) { FileUtils.rm_rf(temp_dir) }

  describe 'GET /data_fix/commit_summary' do
    it 'shows the meeting, the counts, the preflight and one Commit form posting to commit_phase6' do
      allow_commit_guards
      get data_fix_commit_summary_path(file_path: source_file)

      expect(response).to be_successful
      page = response.parsed_body
      expect(page.at_css('#data-fix-commit-summary')).to be_present
      expect(response.body).to include('Summary Spec Meeting')
      expect(page.css('#commit-summary-counts tr[data-summary-row]').map { |row| row.attr('data-summary-row') })
        .to eq(%w[sessions teams swimmers badges events results])
      expect(page.at_css('#commit-summary-preflight')).to be_present
      expect(page.css("form[action='#{commit_phase6_path(file_path: source_file)}']").size).to eq(1)
      expect(page.at_css('#btn-commit-summary')['disabled']).to be_nil
      expect(page.css('ul.nav-tabs .nav-link').size).to eq(5)
    end

    it 'disables the Commit button with the setup notice when the ops DB is not available' do
      allow_commit_guards
      allow(Ops::Database).to receive(:state).and_return(:missing)
      get data_fix_commit_summary_path(file_path: source_file)

      page = response.parsed_body
      expect(page.at_css('#commit-summary-ops-missing')).to be_present
      expect(page.at_css('#btn-commit-summary')['disabled']).to be_present
    end
  end

  describe 'POST /data_fix/commit_phase6 (guards)' do
    it 'refuses a blocked commit and shows the DB sync link on the summary' do
      allow(DataFix::Guards).to receive(:check).and_return(guards(:block))
      expect { post commit_phase6_path(file_path: source_file) }.not_to change(Ops::CommitReport, :count)

      expect(response).to redirect_to(data_fix_commit_summary_path(file_path: source_file, guard: 'block'))
      expect(flash[:error]).to include('block reason')
      follow_redirect!
      expect(response.parsed_body.at_css('#commit-summary-guard-blocked')).to be_present
      expect(response.parsed_body.at_css("#commit-summary-guard-blocked a[href='#{db_sync_path}']")).to be_present
    end

    it 're-renders the summary with the acknowledgement tick on a warning, then commits once ticked' do
      allow(DataFix::Guards).to receive(:check) { |_scope, acknowledged:| guards(:warn, acknowledged:) }
      expect { post commit_phase6_path(file_path: source_file) }.not_to change(Ops::CommitReport, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.at_css('#commit-drift-ack')).to be_present

      perform_enqueued_jobs(only: DataFixCommitJob) { post commit_phase6_path(file_path: source_file), params: { drift_ack: '1' } }
      report = last_report
      expect(response).to redirect_to(data_fix_commit_report_path(report))
      expect(report).to have_attributes(status: 'committed', requested_by_user_id: admin_user.id)
      expect(report.preflight).to include('drift_ack' => true, 'file_path' => source_file)
      expect(GogglesDb::Meeting.find_by(code: meeting_code)).to be_present
    end

    it 'queues the job on the pipeline queue and opens the queued report' do
      allow_commit_guards
      expect { post commit_phase6_path(file_path: source_file) }.to have_enqueued_job(DataFixCommitJob).on_queue('pipeline')
      report = last_report
      expect(report).to have_attributes(status: 'queued', source_base: 'summary_meeting', source_path: source_file, season_id: 262)
      expect(response).to redirect_to(data_fix_commit_report_path(report))
    end
  end

  describe 'GET /data_fix/commit_reports/:id' do
    it 'polls while queued and can be reopened by id after the commit' do
      allow_commit_guards
      post commit_phase6_path(file_path: source_file)
      report = last_report
      get data_fix_commit_report_path(report)
      page = response.parsed_body
      expect(page.at_css('turbo-frame#commit-report-status')['src']).to eq(data_fix_commit_report_status_path(report))
      expect(page.at_css('[data-live-busy="true"]')).to be_present

      perform_enqueued_jobs(only: DataFixCommitJob)
      get data_fix_commit_report_path(report)
      page = response.parsed_body
      expect(page.at_css('#commit-report-state').text).to include(I18n.t('data_fix.commit_report.statuses.committed'))
      expect(page.at_css('[data-live-busy="true"]')).to be_nil
      expect(page.at_css("a[href='#{outbox_path(focus: report.reload.sql_filename)}']")).to be_present

      get data_fix_commit_report_status_path(report)
      expect(response.parsed_body.at_css('turbo-frame#commit-report-status')).to be_present
    end

    it 'redirects to the file list for an unknown report' do
      get data_fix_commit_report_path(id: 999_999)
      expect(response).to redirect_to(pull_result_files_path)
    end
  end
end
