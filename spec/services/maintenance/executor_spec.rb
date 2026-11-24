# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Executor do
  include ActiveJob::TestHelper

  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:tmp_dir) { data_root.join('tmp') }
  let(:season_id) { 242 }
  # The SQL the fake operation plans (changed by an example to simulate live data changing after the dry run).
  let(:sql_lines) { ["-- Fake fix, generated #{Time.current}", 'SET AUTOCOMMIT = 0;', 'START TRANSACTION;', 'UPDATE swimmers SET x=1 WHERE id=2;', 'COMMIT;'] }

  # A minimal operation: prints a line, plans +sql_lines+.
  let(:fake_class) do
    lines = -> { sql_lines }
    Class.new(Maintenance::Operation) do
      self.key = 'spec.fake'
      self.outbox_kind = 'fix'
      self.health_group = 'results'
      self.fixes = %w[results.duplicates].freeze

      param :meeting_id
      validates :meeting_id, presence: true

      define_method(:sql_source) { lines.call }

      def self.params_from_finding(finding) = { 'meeting_id' => finding.subject_id }
      def self.title = 'Fake fix'
      def label = "Fake fix of meeting #{meeting_id}"
      def file_base = "fix_spec-#{meeting_id}"
      def season_id = 242
      def subject = ['meeting', meeting_id]

      protected

      def build_plan
        puts("checking meeting #{meeting_id}") # rubocop:disable RSpec/Output
        blank_plan(summary: { 'meeting_id' => meeting_id }, sql_lines: sql_source)
      end
    end
  end

  before(:each) do
    stub_const('Maintenance::SpecFakeOperation', fake_class)
    allow(Maintenance::Registry).to receive(:find).and_call_original
    allow(Maintenance::Registry).to receive(:find).with('spec.fake').and_return(fake_class)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def create_run(mode: 'preview', **attributes)
    FactoryBot.create(:ops_operation_run, operation_key: 'spec.fake', params: { 'meeting_id' => 7 }, mode:, started_by: 1, **attributes)
  end

  def execute(run, gate: maintenance_gate(:ok), sql_runner: maintenance_sql_runner)
    described_class.new(run:, data_root:, gate:, sql_runner:, tmp_dir:).call
  end

  # A succeeded dry run and its queued apply.
  def previewed_apply(**apply_attributes)
    preview = execute(create_run)
    expect(preview).to be_succeeded
    [preview, create_run(mode: 'apply', parent_run_id: preview.id, **apply_attributes)]
  end

  def sql_files = Dir.glob(data_root.join('results.new/**/*.sql').to_s)

  describe 'preview' do
    it 'stores the console, summary, SQL preview and digest, and writes nothing else' do
      run = create_run
      statements = primary_db_statements { execute(run) }
      expect(statements.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
      expect(run.reload).to have_attributes(status: 'succeeded', console: "checking meeting 7\n", sql_digest: be_present,
                                            season_id:, subject_type: 'meeting', subject_id: 7, applied_locally: false)
      expect(run.sql_preview).to include('UPDATE swimmers SET x=1 WHERE id=2;')
      expect(run.summary_hash).to include('meeting_id' => 7, 'confirmation' => 'one_click', 'empty' => false, 'statements' => 1,
                                          'file_base' => 'fix_spec-7', 'health_group' => 'results')
      expect(sql_files).to be_empty
      expect(Dir.exist?(tmp_dir)).to be(false)
      expect(Ops::SqlScript.count).to eq(0)
      expect(maintenance_sql_runs).to be_empty
    end

    it 'never checks the DB sync gate' do
      gate = maintenance_gate(:block)
      execute(create_run, gate:)
      expect(gate).not_to have_received(:check)
    end

    it 'stores the validation errors of invalid params without raising' do
      run = create_run(params: {})
      execute(run)
      expect(run.reload).to have_attributes(status: 'succeeded', sql_digest: nil)
      expect(run.error_list.first).to include(I18n.t('maintenance.params.meeting_id'))
      expect(run).not_to be_appliable
    end

    it 'lists the Data-Fix reviews in progress of the season' do
      Ops::PipelineSource.create!(season_id:, base: 'spec-meeting-b', stage: 'ready_to_commit')
      Ops::PipelineSource.create!(season_id:, base: 'spec-meeting-c', stage: 'committed')
      run = create_run
      execute(run)
      bases = run.reload.summary_hash['reviews_in_progress'].pluck('base')
      expect(bases).to include('spec-meeting-b')
      expect(bases).not_to include('spec-meeting-c')
    end

    it 'warns about an interrupted apply of the same operation and params (the local DB may already hold its change)' do
      stale = create_run(mode: 'apply', status: 'running', started_at: 2.hours.ago,
                         params_digest: Ops::OperationRun.params_digest_for('meeting_id' => 7))
      create_run(mode: 'apply', status: 'running', started_at: 1.minute.ago) # (recent: not interrupted)
      run = create_run
      execute(run)
      expect(run.reload.warning_list).to eq([I18n.t('maintenance.executor.interrupted_apply', id: stale.id)])
      expect(run).to be_appliable
    end

    it 'leaves a run that is not queued any more untouched' do
      run = create_run(status: 'running')
      execute(run)
      expect(run.reload).to have_attributes(status: 'running', console: nil)
    end
  end

  describe 'apply' do
    let(:finding) { FactoryBot.create(:ops_health_finding, season_id:, group_key: 'results', check_key: 'results.duplicates') }

    it 'runs the SQL locally, then registers exactly one Outbox script, re-runs the health group and links the finding' do # rubocop:disable RSpec/MultipleExpectations
      _preview, apply = previewed_apply(health_finding_id: finding.id)
      expect { execute(apply) }.to have_enqueued_job(Health::SeasonRunJob).exactly(1).times
      apply.reload
      expect(apply).to have_attributes(status: 'succeeded', applied_locally: true, sql_script_id: be_present, console: "checking meeting 7\n",
                                       drift_verdict: 'unknown')
      script = Ops::SqlScript.sole.tap { |row| row.data_root = data_root }
      expect(script).to have_attributes(id: apply.sql_script_id, applied_locally: true, state: 'pending', folder: 'misc', kind: 'fix',
                                        season_id:, filename: "#{format('%04d', script.seq)}-fix_spec-7.sql")
      expect(script.origin).to include('producer' => 'maintenance', 'operation_run_id' => apply.id, 'health_finding_id' => finding.id)
      expect(File.binread(script.absolute_path)).to eq("#{sql_lines.join("\r\n")}\r\n")
      expect(maintenance_sql_runs.map(&:last)).to eq([File.binread(script.absolute_path)])
      expect(Ops::HealthRun.for_season(season_id).pending.pluck(:group_key, :trigger)).to eq([%w[results after_operation]])
      expect(apply.summary_hash).to include('sql_filename' => script.filename, 'health_run_id' => Ops::HealthRun.last.id)
      expect(finding.reload.mitigation_run_id).to eq(apply.id)
      expect(Ops::Event.of_kind('maintenance.applied').sole.data).to include('sql_filename' => script.filename)
      expect(Dir.glob(tmp_dir.join('*').to_s)).to be_empty
    end

    it 'refuses when the data changed since the dry run (digest_changed): nothing run, nothing registered' do
      _preview, apply = previewed_apply
      sql_lines << 'DELETE FROM laps WHERE id=9;'
      execute(apply)
      expect(apply.reload).to have_attributes(status: 'refused', refusal_reason: 'digest_changed')
      expect(maintenance_sql_runs).to be_empty
      expect(Ops::SqlScript.count).to eq(0)
      expect(Ops::Event.of_kind('maintenance.refused').sole.data).to include('reason' => 'digest_changed')
    end

    it 'ignores comment lines in the digest (timestamps in the script header)' do
      _preview, apply = previewed_apply
      sql_lines[0] = '-- Fake fix, generated tomorrow'
      execute(apply)
      expect(apply.reload).to be_succeeded
    end

    it 'leaves no script and no Outbox row when the local apply fails' do
      _preview, apply = previewed_apply
      execute(apply, sql_runner: maintenance_sql_runner(success: false, stderr: 'ERROR 1062 (23000): Duplicate entry'))
      expect(apply.reload).to have_attributes(status: 'failed', applied_locally: false, sql_script_id: nil)
      expect(apply.error_list.first).to include('ERROR 1062')
      expect(Ops::SqlScript.count).to eq(0)
      expect(sql_files).to be_empty
      expect(Dir.glob(tmp_dir.join('*').to_s)).to be_empty
      expect(Ops::Event.of_kind('maintenance.apply_failed').count).to eq(1)
    end

    it 'refuses on a red DB sync gate before planning' do
      _preview, apply = previewed_apply
      allow_any_instance_of(fake_class).to receive(:build_plan).and_raise('must not plan') # rubocop:disable RSpec/AnyInstance
      execute(apply, gate: maintenance_gate(:block))
      expect(apply.reload).to have_attributes(status: 'refused', refusal_reason: 'drift_blocked', drift_verdict: 'unknown')
      expect(maintenance_sql_runs).to be_empty
    end

    it 'refuses a DB sync warning without the operator tick, and applies with it' do
      _preview, apply = previewed_apply
      execute(apply, gate: maintenance_gate(:warn))
      expect(apply.reload).to have_attributes(status: 'refused', refusal_reason: 'drift_unacknowledged')

      _preview2, acked = previewed_apply(drift_ack: true)
      execute(acked, gate: maintenance_gate(:warn))
      expect(acked.reload).to be_succeeded
    end

    it 'refuses without a succeeded dry run, and a second apply of the same dry run' do
      orphan = create_run(mode: 'apply')
      execute(orphan)
      expect(orphan.reload.refusal_reason).to eq('no_preview')

      preview, first = previewed_apply
      execute(first)
      second = create_run(mode: 'apply', parent_run_id: preview.id)
      execute(second)
      expect(second.reload.refusal_reason).to eq('already_applied')
      expect(Ops::SqlScript.count).to eq(1)
    end

    it 'refuses while a DB restore is in progress' do
      allow(DbRestore::Lock).to receive(:active?).and_return(true)
      _preview, apply = previewed_apply
      execute(apply)
      expect(apply.reload.refusal_reason).to eq('restore_in_progress')
    end

    it 'refuses a plan that became empty' do
      _preview, apply = previewed_apply
      sql_lines.replace(['-- nothing left to fix'])
      # (same digest as the dry run, so that only the emptiness refuses it)
      apply.parent_run.update_columns(sql_digest: Digest::SHA256.hexdigest('')) # rubocop:disable Rails/SkipsModelValidations
      execute(apply)
      expect(apply.reload.refusal_reason).to eq('empty')
    end

    it 'bumps the Data-Fix db generation for an operation changing entities' do
      fake_class.bumps_db_generation = true
      _preview, apply = previewed_apply
      expect { execute(apply) }.to change(DataFix::Pipeline, :db_generation).by(1)
    end
  end

  describe 'script_only (rake, phase 13)' do
    it 'registers the script held as not applied locally, without running it' do
      run = create_run(mode: 'script_only')
      execute(run)
      expect(run.reload).to have_attributes(status: 'succeeded', applied_locally: false)
      expect(Ops::SqlScript.sole).to have_attributes(state: 'held', held_reason: 'not_applied_locally', applied_locally: false)
      expect(maintenance_sql_runs).to be_empty
    end
  end

  it 'closes the run as failed on an unexpected error' do
    run = create_run
    allow_any_instance_of(fake_class).to receive(:to_params).and_raise(IOError, 'disk gone') # rubocop:disable RSpec/AnyInstance
    expect { execute(run) }.not_to raise_error
    expect(run.reload).to have_attributes(status: 'failed')
    expect(run.error_list.first).to include('disk gone')
  end
end
