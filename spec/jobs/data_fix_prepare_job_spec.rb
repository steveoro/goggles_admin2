# frozen_string_literal: true

require 'rails_helper'

# Phase 10: the unattended Data-Fix prepare (phases 1-5 only). The phase 1-3 files come from the clean_fin fixture
# (spec/fixtures/data_fix/pipeline, stamped as built); the phase 4/5 recipes and verdicts are stubbed (they need a
# real meeting in the DB). Everything happens under a temporary '<tmp>/results.new/242/' folder.
RSpec.describe DataFixPrepareJob do
  include ActiveJob::TestHelper

  let(:tmp_dir) { Dir.mktmpdir('prepare-job-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: File.join(tmp_dir, 'results.new')) }
  let(:source_path) { pipeline.source_path }
  let(:ok_guards) { DataFix::Guards::Result.new(level: :ok, reasons: [], verdict: nil, acknowledged: false) }

  def perform(origin: 'auto', source: pipeline, **options)
    run = FactoryBot.create(:ops_pipeline_run, kind: 'prepare', origin:, subject_key: source.base, status: 'queued')
    described_class.perform_now(source_path: source.source_path, season_id: 242, origin:, run_id: run.id, **options)
    run.reload
  end

  def file_state(path) = [File.binread(path), File.mtime(path)]

  # Phase 4/5 builds (minimal files) and clean phase 4/5 verdicts; phase 1 structure valid; no relay enrichment.
  def stub_later_phases(on_build: nil)
    allow(DataFix::Pipeline::Recipes).to receive(:build).and_wrap_original do |original, pipe, phase|
      on_build&.call(pipe, phase)
      case phase
      when 4 then PhaseFileManager.new(pipe.phase_path(4)).write!(data: { 'sessions' => [] }, meta: {})
      when 5 then PhaseFileManager.new(pipe.phase_path(5)).write_payload!('name' => 'phase5', 'programs' => [])
      else original.call(pipe, phase)
      end
      {}
    end
    [4, 5].each do |phase|
      allow("DataFix::Verdicts::Phase#{phase}".constantize).to receive(:new) do
        instance_double("DataFix::Verdicts::Phase#{phase}", call: DataFix::Verdict.build(phase:, status: 'clean'))
      end
    end
  end

  before(:each) do
    stub_valid_structure
    allow(DataFix::Guards).to receive(:check).and_return(ok_guards)
    allow(DataFix::Pipeline).to receive(:for).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |pipe| pipe.relay_enrichment_count = 0 }
    end
    allow(SeasonBoard::Notifier).to receive(:ping)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'runs on the pipeline queue with priority 10, under the data_fix_pipeline concurrency key' do
    job = described_class.new(source_path: 'x', season_id: 242, origin: 'auto')
    expect(job.queue_name).to eq('pipeline')
    expect(job.priority).to eq(10)
    expect(described_class.concurrency_limit).to eq(1)
    expect(job.concurrency_key).to end_with('data_fix_pipeline')
  end

  it 'has no retry or discard handler' do
    expect(described_class.rescue_handlers).to be_empty
  end

  it 'sets the soft deadline from the step 1 benchmark (20 minutes)' do
    expect(described_class::DEADLINE).to eq(20.minutes)
  end

  describe 'on the clean_fin fixture' do
    before(:each) { stub_later_phases }

    it 'reaches ready_to_commit with zero clicks, committing and pushing nothing' do
      meetings = GogglesDb::Meeting.count
      scripts = Ops::SqlScript.count
      run = nil
      expect { run = perform }.not_to have_enqueued_job(DataFixCommitJob)

      expect(run).to have_attributes(status: 'done', pipeline_source_id: pipeline.source_row.id)
      expect(pipeline.source_row.reload).to have_attributes(stage: 'ready_to_commit', new_teams_count: 2, new_swimmers_count: 37,
                                                            lease_owner: nil, failed_source_sha256: nil)
      expect(Ops::CommitReport.count).to eq(0)
      expect(GogglesDb::Meeting.count).to eq(meetings)
      expect(Ops::SqlScript.count).to eq(scripts)
      expect(File).to exist(pipeline.phase_path(5))
    end

    it 'builds only the missing phases (the fresh phases 1-3 are kept as they are)' do
      before = (1..3).index_with { |phase| file_state(pipeline.phase_path(phase)) }
      perform
      expect((1..3).index_with { |phase| file_state(pipeline.phase_path(phase)) }).to eq(before)
      expect(DataFix::Pipeline::Recipes).to have_received(:build).twice
    end

    it 'holds the lease as job:<job id> during the run and releases it afterwards' do
      owners = []
      allow(DataFix::Pipeline::Recipes).to receive(:build).and_wrap_original do |_original, pipe, phase|
        owners << pipe.source_row.reload.lease_owner
        PhaseFileManager.new(pipe.phase_path(phase)).write!(data: { 'sessions' => [] }, meta: {}) if phase == 4
        PhaseFileManager.new(pipe.phase_path(phase)).write_payload!('name' => 'phase5', 'programs' => []) if phase == 5
        {}
      end
      perform
      expect(owners.uniq.size).to eq(1)
      expect(owners.first).to start_with('job:')
      expect(pipeline.source_row.reload.lease_owner).to be_nil
    end

    it 'enqueues the next planner pass after a successful run' do
      expect { perform }.to have_enqueued_job(PipelinePlannerJob).with(trigger: 'DataFixPrepareJob')
    end

    it 'records the queued -> running -> done prepare in the activity log of the FIN id' do
      perform(fin_event_id: '150091')
      expect(SeasonBoard::ActivityLog.new.entry('150091', :prepare)).to have_attributes(status: :done, origin: :auto)
    end
  end

  describe 'source resolution (DataFix::SourceResolver can rewrite the working copy)' do
    it 'never runs the rewriting resolver branches for an automatic run on a source with phase files' do
      stub_later_phases
      calls = 0
      allow_any_instance_of(DataFix::SourceResolver).to receive(:resolve_working_source_path).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
        calls += 1
        original.call(*args)
      end
      expect(perform.status).to eq('done')
      expect(calls).to eq(0)
    end

    it 'refuses an automatic run on a source with phase files whose categories the resolver would normalize' do
      stub_later_phases
      allow_any_instance_of(DataFix::SourceResolver).to receive(:lt4_result_categories_need_normalization?).and_return(true) # rubocop:disable RSpec/AnyInstance
      before = File.binread(source_path)
      expect(perform).to have_attributes(status: 'refused', error: 'source_needs_review')
      expect(File.binread(source_path)).to eq(before)
      expect((1..3).map { |phase| File.exist?(pipeline.phase_path(phase)) }).to eq([true, true, true])
    end

    it 'checks the edits and takes the lease before resolving a fresh automatic source' do
      fresh_dir = File.join(tmp_dir, 'fresh', 'results.new', '242')
      FileUtils.mkdir_p(fresh_dir)
      lt2 = File.join(fresh_dir, 'fresh.json')
      File.write(lt2, JSON.generate('layoutType' => 2, 'name' => 'Fresh', 'sections' => []))
      Ops::PipelineSource.for_path!(lt2).acquire_lease!('operator:1:x')
      resolver_calls = 0
      allow_any_instance_of(DataFix::SourceResolver).to receive(:resolve_working_source_path) { resolver_calls += 1 } # rubocop:disable RSpec/AnyInstance
      run = FactoryBot.create(:ops_pipeline_run, kind: 'prepare', origin: 'auto', subject_key: 'fresh', status: 'queued')
      described_class.perform_now(source_path: lt2, season_id: 242, origin: 'auto', run_id: run.id)
      expect(run.reload).to have_attributes(status: 'refused', error: start_with('lease_busy'))
      expect(resolver_calls).to eq(0)
    end
  end

  describe 'operator edits' do
    it 'refuses an automatic run on a source holding pre-existing (adopted) phase files, leaving them byte-identical' do
      adopted = pipeline_from_fixture('clean_fin', dir: File.join(tmp_dir, 'adopted', 'results.new'), stamped: false)
      before = (1..3).index_with { |phase| file_state(adopted.phase_path(phase)) }
      stub_later_phases

      run = perform(source: adopted)
      expect(run).to have_attributes(status: 'refused', error: 'edited')
      expect((1..3).index_with { |phase| file_state(adopted.phase_path(phase)) }).to eq(before)
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
      expect(File).not_to exist(adopted.phase_path(4))
    end

    it 'never writes an edited phase 2 when an operator-requested run rebuilds phase 3 (no harmonizer write)' do
      pipeline.mark_edited!(2, action: 'update_phase2_team')
      FileUtils.rm_f(pipeline.phase_path(3))
      edited = file_state(pipeline.phase_path(2))
      stub_later_phases(on_build: lambda { |pipe, phase|
        PhaseFileManager.new(pipe.phase_path(3)).write!(data: { 'swimmers' => [], 'badges' => [] }, meta: {}) if phase == 3
      })
      allow(Import::Solvers::SwimmerSolver).to receive(:new).and_return(instance_double(Import::Solvers::SwimmerSolver, build!: nil))
      allow(DataFix::Phase3Harmonizer).to receive(:harmonize_phase2_phase3_team_links)

      perform(origin: 'operator')
      expect(file_state(pipeline.phase_path(2))).to eq(edited)
      expect(DataFix::Phase3Harmonizer).not_to have_received(:harmonize_phase2_phase3_team_links)
    end
  end

  describe 'start guards and stops' do
    it 'refuses an automatic run while auto_prepare is off (ADMIN2_AUTOMATION=0)' do
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      stub_later_phases
      expect(perform).to have_attributes(status: 'refused', error: 'automation_paused')
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
    end

    it 'runs an operator-requested prepare with the automation off' do
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      stub_later_phases
      expect(perform(origin: 'operator')).to have_attributes(status: 'done')
    end

    it 'refuses while the lease is held by someone else' do
      pipeline.source_row.acquire_lease!('operator:1:abcd')
      stub_later_phases
      expect(perform).to have_attributes(status: 'refused', error: start_with('lease_busy: '))
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
      expect(pipeline.source_row.reload.lease_owner).to eq('operator:1:abcd')
    end

    it 'refuses on a red DB sync verdict (drift block) or a DB restore, and builds on a warning, noting it on the run' do
      stub_later_phases
      allow(DataFix::Guards).to receive(:check)
        .and_return(DataFix::Guards::Result.new(level: :block, reasons: ['id collision'], verdict: nil, acknowledged: false))
      expect(perform).to have_attributes(status: 'refused', error: 'drift_red: id collision')

      allow(DataFix::Guards).to receive(:check)
        .and_return(DataFix::Guards::Result.new(level: :block, reasons: ['restoring'], verdict: :restore, acknowledged: false))
      expect(perform).to have_attributes(status: 'refused', error: 'db_restore: restoring')

      allow(DataFix::Guards).to receive(:check)
        .and_return(DataFix::Guards::Result.new(level: :warn, reasons: ['DB sync unknown'], verdict: nil, acknowledged: false))
      run = perform
      expect(run.status).to eq('done')
      expect(run.message).to include('DB sync unknown')
    end

    it 'makes no remote write: with the real guards, any API call is the drift gate GET' do
      allow(DataFix::Guards).to receive(:check).and_call_original
      calls = []
      allow(APIProxy).to receive(:call) do |options|
        calls << options
        DummyResponse.new(body: '{}')
      end
      stub_later_phases
      perform
      expect(calls.pluck(:method).uniq - [:get]).to eq([])
      expect(Ops::RemoteWrite.count).to eq(0)
    end

    it 'fails closed: an unreadable switch refuses an automatic run, an unreadable commit check counts as pending' do
      stub_later_phases
      allow(Ops::Setting).to receive(:fetch).and_call_original
      allow(Ops::Setting).to receive(:fetch).with('automation.enabled', true).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(perform).to have_attributes(status: 'refused', error: 'automation_paused')

      allow(Ops::Setting).to receive(:fetch).and_call_original
      allow(Ops::CommitReport).to receive(:pending).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(perform).to have_attributes(status: 'refused', error: 'commit_pending')
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
    end

    it 'yields when the queued-commit check cannot be read' do
      stub_later_phases
      allow(Ops::CommitReport).to receive(:exists?).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(perform.status).to eq('yielded')
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
    end

    it 'refuses a source no longer in results.new' do
      FileUtils.rm_f(source_path)
      stub_later_phases
      expect(perform).to have_attributes(status: 'refused', error: 'source_missing')
    end

    it 'refuses while a commit of the source is pending' do
      FactoryBot.create(:ops_commit_report, source_base: pipeline.base, status: 'queued')
      stub_later_phases
      expect(perform).to have_attributes(status: 'refused', error: 'commit_pending')
    end

    it 'fails with reason deadline when the soft deadline has passed between two phases' do
      stub_later_phases
      saved = described_class.deadline
      described_class.deadline = -1.second
      run = perform
      expect(run).to have_attributes(status: 'failed', error: 'deadline')
      expect(pipeline.source_row.reload).to have_attributes(stage: 'failed', failed_source_sha256: Digest::SHA256.file(source_path).hexdigest)
    ensure
      described_class.deadline = saved
    end

    it 'yields to a queued commit between phases, enqueuing nothing' do
      FactoryBot.create(:ops_commit_report, source_base: 'another-meeting', status: 'queued')
      stub_later_phases
      run = nil
      expect { run = perform }.not_to have_enqueued_job(PipelinePlannerJob)
      expect(run.status).to eq('yielded')
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
      expect(File).not_to exist(pipeline.phase_path(4))
      expect(pipeline.source_row.reload.stage).not_to eq('preparing')
    end

    it 'records the verdicts stale when the source changed during the run' do
      stub_later_phases(on_build: ->(pipe, phase) { File.write(pipe.source_path, "#{File.read(pipe.source_path)}\n") if phase == 4 })
      run = perform
      expect(run.status).to eq('done')
      expect(run.message).to include(I18n.t('pipeline_automation.reasons.source_changed'))
      expect(Ops::PhaseVerdict.where(pipeline_source_id: pipeline.source_row.id, status: 'stale')).to exist
      expect(pipeline.source_row.reload.stage).to eq('needs_review')
    end
  end

  describe 'failures' do
    it 'never raises: a failing build closes the run as failed, with the stage and the source SHA256' do
      stub_later_phases(on_build: ->(_pipe, phase) { raise StandardError, 'solver exploded' if phase == 4 })
      run = nil
      expect { run = perform }.not_to raise_error
      expect(run).to have_attributes(status: 'failed', phase: 4)
      expect(run.error).to include('solver exploded')
      expect(pipeline.source_row.reload).to have_attributes(stage: 'failed', lease_owner: nil)
      expect(pipeline.source_row.failed_source_sha256).to eq(Digest::SHA256.file(source_path).hexdigest)
    end

    it 'enqueues no planner pass after a failure' do
      stub_later_phases(on_build: ->(_pipe, phase) { raise StandardError, 'boom' if phase == 4 })
      expect { perform }.not_to have_enqueued_job(PipelinePlannerJob)
    end
  end
end
