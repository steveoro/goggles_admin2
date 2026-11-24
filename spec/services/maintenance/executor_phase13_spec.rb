# frozen_string_literal: true

require 'rails_helper'

# Maintenance::Executor, phase 13 additions: season folder and held script (standard timings), the text appended after
# a local apply, progress and cancel of a long plan, the rake script format (bytes, explicit prefix, former name).
RSpec.describe Maintenance::Executor do
  include ActiveJob::TestHelper
  include ViewComponent::TestHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:tmp_dir) { data_root.join('tmp') }
  let(:progress_steps) { 0 }

  let(:fake_class) do
    steps = -> { progress_steps }
    Class.new(Maintenance::Operation) do
      self.key = 'spec.fake13'
      self.outbox_kind = 'standard_timings'
      self.health_group = 'setup'
      self.cancellable = true

      param :season_id

      define_method(:progress_steps) { steps.call }

      def self.title = 'Fake 13'
      def file_base = "#{season_id}-fake13"
      def outbox_folder = season_id.to_s
      def held_reason = 'remote_season_missing'
      def after_local_apply(_plan) = $stdout.puts('verified: OK')

      protected

      def build_plan
        progress_steps.times { |index| report_progress(index, progress_steps, "item #{index}") }
        report_progress(progress_steps, progress_steps, 'done') if progress_steps.positive?
        blank_plan(sql_lines: ['START TRANSACTION;', "INSERT INTO standard_timings (season_id) VALUES (#{season_id});", 'COMMIT;'])
      end
    end
  end

  before(:each) do
    stub_const('Maintenance::SpecFake13Operation', fake_class)
    allow(Maintenance::Registry).to receive(:find).and_call_original
    allow(Maintenance::Registry).to receive(:find).with('spec.fake13').and_return(fake_class)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def create_run(mode: 'preview', **attributes)
    FactoryBot.create(:ops_operation_run, operation_key: 'spec.fake13', params: { 'season_id' => 262 }, mode:, season_id: 262, **attributes)
  end

  def execute(run, **options)
    described_class.new(run:, data_root:, gate: maintenance_gate(:ok), sql_runner: maintenance_sql_runner, tmp_dir:, **options).call
  end

  it 'registers the script of a local apply in the operation folder, held for its reason, and appends the after-apply text' do
    preview = execute(create_run)
    apply = perform_enqueued_jobs { execute(create_run(mode: 'apply', parent_run_id: preview.id)) }
    expect(apply.reload).to have_attributes(status: 'succeeded', applied_locally: true)
    script = apply.sql_script
    expect(script).to have_attributes(folder: '262', state: 'held', held_reason: 'remote_season_missing', applied_locally: true)
    expect(script.rel_path).to match(%r{\Aresults\.new/262/\d{4}-262-fake13\.sql\z})
    expect(apply.console).to end_with("verified: OK\n")
  end

  it 'writes the rake bytes, the explicit prefix and the former name when the rake caller gives them' do
    run = execute(create_run(mode: 'script_only', origin: 'rake'), script_text: Maintenance::RakeRunner::SCRIPT_TEXT, script_prefix: 42,
                                                                   script_name: 'former-name', origin: { 'task' => 'import:x' })
    script = run.reload.sql_script
    expect(script).to have_attributes(filename: '0042-former-name.sql', state: 'held', held_reason: 'not_applied_locally')
    expect(File.binread(data_root.join(script.rel_path))).to eq("START TRANSACTION;\r\nINSERT INTO standard_timings (season_id) VALUES (262);\r\nCOMMIT;\n")
    expect(script.origin).to include('task' => 'import:x', 'producer' => 'maintenance')
  end

  context 'with a long plan' do
    let(:progress_steps) { 3 }

    it 'stores the progress on the run while planning' do
      run = create_run
      execute(run)
      # (throttled: the first report and the last one are stored)
      expect(run.reload.progress_hash).to eq('done' => 3, 'total' => 3, 'label' => 'done')
      expect(run.progress_percent).to eq(100)
    end

    it 'stops at the next progress report once the operator asked to cancel, refused "cancelled"' do
      run = create_run
      allow(Ops::OperationRun).to receive(:where).and_call_original
      run.update_columns(cancel_requested_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      execute(run)
      expect(run.reload).to have_attributes(status: 'refused', refusal_reason: 'cancelled', progress: nil)
      expect(Dir.glob(data_root.join('results.new/**/*.sql').to_s)).to be_empty
    end
  end

  # (review of phase 13: a script with several transaction blocks is not atomic on MariaDB)
  context 'with a script of several transaction blocks (one per badge)' do
    let(:block_class) do
      Class.new(Maintenance::Operation) do
        self.key = 'spec.blocks13'
        self.outbox_kind = 'merge'
        self.health_group = 'badges'

        param :season_id

        def self.title = 'Fake blocks'
        def file_base = "season_fix_#{season_id}-step1-sure"

        protected

        def build_plan
          blank_plan(sql_lines: ['-- header', *(1..3).flat_map { |n| ['', 'START TRANSACTION;', "UPDATE badges SET x=#{n} WHERE id=#{n};", 'COMMIT;'] }])
        end
      end
    end
    let(:block_runs) { [] }

    before(:each) do
      stub_const('Maintenance::SpecBlocks13Operation', block_class)
      allow(Maintenance::Registry).to receive(:find).with('spec.blocks13').and_return(block_class)
    end

    def block_run(mode: 'preview', **attributes)
      FactoryBot.create(:ops_operation_run, operation_key: 'spec.blocks13', params: { 'season_id' => 182 }, mode:, season_id: 182, **attributes)
    end

    # A LocalDb::SqlRunner stand-in failing on the block holding +failing+ (nil: never).
    def block_runner(failing: nil)
      runner = class_double(LocalDb::SqlRunner)
      allow(runner).to receive(:call) do |path:|
        text = File.binread(path)
        block_runs << text
        ok = failing.nil? || text.exclude?(failing)
        LocalDb::SqlRunner::Result.new(success: ok, stdout: '', stderr: ok ? '' : 'ERROR 1062 (23000): Duplicate entry', duration: 0.01, exit_code: ok ? 0 : 1)
      end
      runner
    end

    def apply_with(runner, writer_error: nil)
      preview = execute(block_run)
      apply = block_run(mode: 'apply', parent_run_id: preview.id)
      allow(Outbox::Writer).to receive(:write!).and_raise(Outbox::Error, writer_error) if writer_error
      perform_enqueued_jobs do
        described_class.new(run: apply, data_root:, gate: maintenance_gate(:ok), sql_runner: runner, tmp_dir:).call
      end
      [preview, apply.reload]
    end

    it 'runs each block alone and registers the whole script (same bytes) when every block ran' do
      _preview, apply = apply_with(block_runner)
      expect(block_runs.size).to eq(3)
      expect(block_runs.first).to start_with("-- header\r\n\r\nSTART TRANSACTION;\r\nUPDATE badges SET x=1 WHERE id=1;")
      expect(apply).to have_attributes(status: 'succeeded', applied_locally: true)
      text = File.binread(data_root.join(apply.sql_script.rel_path))
      expect(text.scan('START TRANSACTION;').size).to eq(3)
      expect(Dir.glob(tmp_dir.join('*').to_s)).to be_empty
    end

    it 'registers exactly the blocks that ran when a later block fails (nothing applied is lost)' do
      _preview, apply = apply_with(block_runner(failing: 'x=2'))
      expect(block_runs.size).to eq(2) # (block 3 never ran)
      expect(apply).to have_attributes(status: 'failed', applied_locally: true, applied_with_failure?: true)
      script = apply.sql_script
      text = File.binread(data_root.join(script.rel_path))
      expect(text).to start_with('-- PARTIAL LOCAL APPLY')
      expect(text).to include('x=1')
      expect(text).not_to include('x=2', 'x=3')
      expect(script).to have_attributes(state: 'pending', applied_locally: true)
      expect(apply.summary_hash['partial']).to eq('applied_blocks' => 1, 'total_blocks' => 3)
    end

    it 'fails the partial run naming the failed block, and consumes the dry run (a new one plans what is left)' do
      preview, apply = apply_with(block_runner(failing: 'x=2'))
      script = apply.sql_script
      expect(apply.error_list.sole).to eq(I18n.t('maintenance.executor.partial_apply', applied: 1, total: 3, block: 2, file: script.filename,
                                                                                       error: 'ERROR 1062 (23000): Duplicate entry'))
      expect(preview.reload).to be_applied_or_applying # (the dry run is consumed: a new one plans what is left)
      component = Maintenance::PlanReportComponent.new(run: apply)
      expect(render_inline(component).css('#operation-run-outcome').text).to include(script.filename)
    end

    it 'registers nothing when the first block fails' do
      _preview, apply = apply_with(block_runner(failing: 'x=1'))
      expect(apply).to have_attributes(status: 'failed', applied_locally: false, sql_script_id: nil)
      expect(Dir.glob(data_root.join('results.new/**/*.sql').to_s)).to be_empty
    end

    it 'keeps the SQL that ran and says so when the Outbox registration fails after the local apply' do
      _preview, apply = apply_with(block_runner, writer_error: "'0012-x.sql' already exists")
      expect(apply).to have_attributes(status: 'failed', applied_locally: true, sql_script_id: nil)
      kept = apply.unregistered_sql_path
      expect(File.binread(kept).scan('START TRANSACTION;').size).to eq(3)
      expect(apply.summary_hash['outbox_folder']).to eq('misc')
      outcome = render_inline(Maintenance::PlanReportComponent.new(run: apply)).css('#operation-run-outcome').text
      expect(outcome).to include(kept, 'results.new/misc/')
    end
  end

  describe Ops::OperationRun do
    it 'cancels a queued run at once, asks a running one to stop, never a finished one' do
      queued = create_run
      expect(queued).to be_cancellable
      expect(queued.request_cancel!).to be(true)
      expect(queued.reload).to have_attributes(status: 'refused', refusal_reason: 'cancelled')
      running = create_run(status: 'running', started_at: Time.current)
      expect(running.request_cancel!).to be(true)
      expect(running.reload).to have_attributes(status: 'running', cancel_requested?: true, cancellable?: false)
      expect(create_run(status: 'succeeded').request_cancel!).to be(false)
    end
  end
end
