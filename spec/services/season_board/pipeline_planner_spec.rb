# frozen_string_literal: true

require 'rails_helper'
require_relative 'disk_fixtures'

# Phase 10: the state-driven planner, on a real board build (temporary data dir, ops test DB). The Scheduler calls are
# stubbed: what matters here is what gets queued, and what never does.
RSpec.describe SeasonBoard::PipelinePlanner do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('pipeline-planner') }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 9, 1), end_date: Date.new(2027, 8, 31)) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:db_index) { instance_double(SeasonBoard::DbIndex, duplicate_fin_event_ids: [], orphans: [], calendar_for: nil) }
  let(:fin_id) { '150091' }
  let(:preflight) { -> {} }
  let(:run) { instance_double(Ops::PipelineRun, present?: true) }

  def fin_row(fin = fin_id)
    { 'year' => '2026', 'date' => '08/11', 'name' => "Meeting #{fin}", 'place' => 'Somewhere', 'url' => results_url(fin), 'info' => '',
      'key' => "2026 | 08/11 | Meeting #{fin}" }
  end

  def builder(rows = [fin_row])
    SeasonBoard::Builder.new(season:, rows:, disk_index: SeasonBoard::DiskIndex.new(season_id: 262, data_dir:), db_index:, activity_log:,
                             today: Date.new(2026, 11, 12))
  end

  def plan(rows = [fin_row])
    described_class.new(season:, builder: builder(rows), activity_log:, extract_preflight: preflight).call
  end

  # A results LT4 source 'm' (FIN id inside) with phase files, stamped as built unless +stamped+ is false (pre-09 files).
  def prepared_source!(stamped: true, phases: 1..3)
    source = write_json('results.new', 'm-lt4.json', lt4_hash(fin_id:, results: true))
    phases.each do |phase|
      PhaseFileManager.new(source.sub('.json', "-phase#{phase}.json")).write!(data: { 'teams' => [], 'swimmers' => [] }, meta: {})
    end
    pipe = DataFix::Pipeline.for(source, progress: Import::Progress::Null.new, actor: :auto)
    phases.each { |phase| pipe.send(:stamp_built!, phase) } if stamped
    source
  end

  # Ops facts of the source 'm': stage + five verdicts (+statuses+: phase => status, default clean).
  # (rows already written by the pipeline itself, e.g. by mark_edited!, are updated in place)
  def pipeline!(stage:, statuses: {}, **attributes)
    source = Ops::PipelineSource.find_or_initialize_by(season_id: 262, base: 'm')
    source.update!(source_path: path_for('results.new', 'm-lt4.json'), stage:, db_generation: DataFix::Pipeline.db_generation, **attributes)
    (1..5).each do |phase|
      verdict = Ops::PhaseVerdict.find_or_initialize_by(pipeline_source: source, phase:)
      verdict.update!(status: statuses.fetch(phase, 'clean'), issues: [], counts: {}, new_entities: {}, checked_at: 2.seconds.from_now)
    end
    source
  end

  def prepare_calls
    calls = []
    allow(SeasonBoard::Scheduler).to receive(:prepare!) { |**args| (calls << args) && run }
    calls
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Snapshot).to receive(:build!) { |_season, builder:| builder.call }
    allow(SeasonBoard::Scheduler).to receive_messages(prepare!: run, extract!: true)
  end

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  describe 'prepare rules' do
    it 'results_ready => prepare up to phase 5 (origin auto, through the Scheduler)' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      calls = prepare_calls
      expect(plan.prepares).to eq([fin_id])
      expect(calls).to eq([{ season_id: 262, source_path: path_for('results.new', 'm.json'), origin: :auto, fin_event_id: fin_id,
                             up_to: 5, mode: 'prepare', phases: nil }])
    end

    it 'structure_ready (manifest-derived source) => prepare up to phase 1' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:))
      write_json('results.new', 'm-lt4.json', lt4_hash(meeting_only: true))
      calls = prepare_calls
      plan
      expect(calls.sole).to include(up_to: 1, mode: 'prepare', source_path: path_for('results.new', 'm-lt4.json'))
    end

    it 'crawled_no_manifest (result-free crawl) => prepare up to phase 1' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:))
      calls = prepare_calls
      plan
      expect(calls.sole).to include(up_to: 1, mode: 'prepare', source_path: path_for('results.new', 'm.json'))
    end

    it 'needs_review with a stale verdict and no edited phase => rebuild_stale' do
      prepared_source!
      pipeline!(stage: 'needs_review', review_phase: 2, statuses: { 2 => 'stale' })
      calls = prepare_calls
      expect(plan.prepares).to eq([fin_id])
      expect(calls.sole).to include(mode: 'rebuild_stale', up_to: 5, phases: nil)
    end

    # 0.10.99: Scheduler.prepare! stores the board's review path (the LT2) on the source row; a prepare refused before it
    # started leaves it there. The edit check must still read the '<base>-lt4-phaseN.json' files of the working copy.
    it 'checks the edits on the working copy when the stored source path is still the LT2 (no false :edited)' do
      prepared_source!
      lt2 = write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      pipeline!(stage: 'needs_review', review_phase: 2, statuses: { 2 => 'stale' }).update!(source_path: lt2)
      calls = prepare_calls
      result = plan
      expect(result.skipped).to eq({})
      expect(calls.sole).to include(mode: 'rebuild_stale')
    end

    it 'ready_to_commit with new entities and a newer db generation => refresh_new_entities' do
      prepared_source!
      pipeline!(stage: 'ready_to_commit', new_teams_count: 2, new_swimmers_count: 0, db_generation: DataFix::Pipeline.db_generation - 1)
      calls = prepare_calls
      plan
      expect(calls.sole).to include(mode: 'refresh_new_entities')
    end

    it 'phase 5 blocked by a collision whose other source is now committed => rebuild_stale of phase 5 only' do
      prepared_source!
      source = pipeline!(stage: 'blocked', review_phase: 5, statuses: { 5 => 'blocked' })
      source.phase_verdicts.find_by(phase: 5).update!(issues: [{ 'code' => 'collisions', 'level' => 'blocked', 'details' => ['other-lt4.json'] }])
      FactoryBot.create(:ops_commit_report, source_base: 'other', status: 'committed', finished_at: 1.minute.from_now)
      calls = prepare_calls
      plan
      expect(calls.sole).to include(mode: 'rebuild_stale', phases: [5])
    end

    it 'leaves a collision alone while the other source is not committed' do
      prepared_source!
      source = pipeline!(stage: 'blocked', review_phase: 5, statuses: { 5 => 'blocked' })
      source.phase_verdicts.find_by(phase: 5).update!(issues: [{ 'code' => 'collisions', 'level' => 'blocked', 'details' => ['other-lt4.json'] }])
      expect(plan.prepares).to be_empty
    end

    it 'never queues anything for a clean, fresh ready_to_commit row (no commit path)' do
      prepared_source!
      pipeline!(stage: 'ready_to_commit')
      expect(plan.prepares).to be_empty
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    # 0.10.99: a source prepared in one go keeps the verdict of step 1 from before the later steps were built.
    describe 'a just-prepared source (time-spaced phase files, each verdict after its own file)' do
      let(:base_time) { 1.hour.ago }

      def at(minutes) = (base_time + minutes.minutes).to_time

      # Working copy at the base time, phase N at +10N minutes; verdict N at +10N+1 (+31 for 4 and 5), or +verdict1 for
      # the first one.
      def spaced!(verdict1: 11)
        source = prepared_source!
        File.utime(at(0), at(0), source)
        (1..3).each { |phase| File.utime(at(10 * phase), at(10 * phase), source.sub('.json', "-phase#{phase}.json")) }
        row = pipeline!(stage: 'ready_to_commit')
        (1..5).each do |phase|
          row.phase_verdicts.find_by(phase:).update!(checked_at: at(phase == 1 ? verdict1 : (10 * [phase, 3].min) + 1))
        end
        row
      end

      it 'queues nothing: the row is ready to commit' do
        spaced!
        expect(builder.call.rows.first.state).to eq(:ready_to_commit)
        expect(plan.prepares).to be_empty
        expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
      end

      it 'skips a rebuild of outdated verdicts when the last prepare ended done after the newest file (:unchanged_since_run)' do
        row = spaced!(verdict1: 5) # (verdict 1 older than the phase 1 file: not fresh)
        FactoryBot.create(:ops_pipeline_run, pipeline_source: row, kind: 'prepare', origin: 'auto', status: 'done', finished_at: at(40))
        expect(builder.call.rows.first.state).to eq(:needs_review)
        expect(plan.skipped).to eq(fin_id => :unchanged_since_run)
        expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)

        File.utime(Time.current.to_time, Time.current.to_time, path_for('results.new', 'm-lt4-phase3.json'))
        calls = prepare_calls
        plan
        expect(calls.sole).to include(mode: 'rebuild_stale', phases: nil)
      end
    end

    it 'prepare_failed with the source unchanged => nothing (the operator retries)' do
      prepared_source!
      File.utime(3.hours.ago.to_time, 3.hours.ago.to_time, path_for('results.new', 'm-lt4.json'))
      source = pipeline!(stage: 'failed')
      source.update!(failed_source_sha256: Digest::SHA256.file(path_for('results.new', 'm-lt4.json')).hexdigest)
      FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', origin: 'auto', status: 'failed', finished_at: 1.hour.ago)
      expect(plan.prepares).to be_empty
    end

    it 'a failed source whose file changed since the failure => prepare again' do
      prepared_source!
      source = pipeline!(stage: 'failed')
      source.update!(failed_source_sha256: 'another-sha')
      FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', origin: 'auto', status: 'failed', finished_at: 1.hour.ago)
      calls = prepare_calls
      plan
      expect(calls.sole).to include(mode: 'prepare', up_to: 5)
    end

    it 'sql_pending and the done states => nothing' do
      write_json('results.done', 'm.json', lt2_hash(fin_id:))
      write_file('results.new', '0420-m-lt4.sql')
      expect(plan.prepares).to be_empty
    end
  end

  describe 'operator edits win' do
    it 'never prepares phase files from before 09 (no ops row: adopted, the row stays :in_review)' do
      prepared_source!(stamped: false)
      row = builder.call.rows.first
      expect(row.state).to eq(:in_review)
      expect(plan.prepares).to be_empty
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    it 'never prepares adopted pre-09 files even with stale verdicts stored (checked on the files themselves)' do
      prepared_source!(stamped: false)
      pipeline!(stage: 'needs_review', review_phase: 1, statuses: { 1 => 'stale' })
      result = plan
      expect(result.prepares).to be_empty
      expect(result.skipped).to eq(fin_id => :edited)
    end

    it 'never prepares a source with an operator edit marker (edited phase => the row Prepare button only)' do
      source = prepared_source!
      DataFix::Pipeline.for(source, progress: Import::Progress::Null.new, actor: :operator).mark_edited!(2, action: 'update_phase2_team')
      pipeline!(stage: 'needs_review', review_phase: 3, statuses: { 3 => 'stale' })
      expect(plan.skipped).to eq(fin_id => :edited)
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    it 'skips a held row' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', source_path: path_for('results.new', 'm.json'), auto_prepare: false)
      expect(plan.skipped).to eq(fin_id => :held)
    end

    it 'skips a busy row and a row prepared less than 10 minutes ago' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      activity_log.queue!(fin_id, kind: :crawl, origin: :auto)
      expect(plan.prepares).to be_empty

      activity_log.finish!(fin_id, kind: :crawl, status: :done)
      source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', source_path: path_for('results.new', 'm.json'))
      FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', origin: 'auto', status: 'refused', finished_at: 5.minutes.ago)
      expect(plan.skipped).to eq(fin_id => :recent_run)
    end

    it 'queues at most MAX_PREPARES_PER_PASS prepares per pass' do
      ids = (1..7).map { |n| "15010#{n}" }
      ids.each { |id| write_json('results.new', "m#{id}.json", lt2_hash(fin_id: id, results: true)) }
      expect(plan(ids.map { |id| fin_row(id) }).prepares.size).to eq(described_class::MAX_PREPARES_PER_PASS)
    end
  end

  describe 'kill switches' do
    before(:each) { write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true)) }

    it 'queues nothing with automation.enabled off' do
      DataFix::Automation.store!(:enabled, false)
      expect(plan).to have_attributes(prepares: [], extractions: [])
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
      expect(SeasonBoard::Snapshot).not_to have_received(:build!)
    end

    it 'queues nothing with ADMIN2_AUTOMATION=0, whatever the stored switches' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('ADMIN2_AUTOMATION', '').and_return('0')
      expect(plan.prepares).to be_empty
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    it 'queues no prepare with automation.auto_prepare off' do
      DataFix::Automation.store!(:auto_prepare, false)
      expect(plan.prepares).to be_empty
    end

    it 'fails closed: queues nothing when a stored switch cannot be read (e.g. a locked ops DB)' do
      DataFix::Automation.store!(:enabled, false)
      allow(Ops::Setting).to receive(:fetch).and_call_original
      allow(Ops::Setting).to receive(:fetch).with('automation.enabled', true).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(plan).to have_attributes(prepares: [], extractions: [])
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    it 'queues no prepare when the ops pipeline facts of the build could not be read' do
      allow(Ops::PipelineSource).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(plan.prepares).to be_empty
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end
  end

  describe 'automatic extraction' do
    let(:pdf) { path_for('manifests', 'manifest-m.pdf') }

    before(:each) do
      write_json('results.new', 'm.json', lt2_hash(fin_id:))
      write_file('manifests', 'manifest-m.pdf')
    end

    def failed_extraction!(at:)
      FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'failed', finished_at: at,
                                           created_at: at)
    end

    it 'manifest_pending => an automatic extraction of the pending PDF' do
      expect(plan.extractions).to eq([fin_id])
      expect(SeasonBoard::Scheduler).to have_received(:extract!).with(season_id: 262, fin_event_id: fin_id, origin: :auto, pdf_path: pdf)
    end

    it 'checks the engine once per pass and queues nothing while it is down' do
      calls = 0
      down = lambda {
        calls += 1
        :engine_unavailable
      }
      result = described_class.new(season:, builder: builder, activity_log:, extract_preflight: down).call
      expect(result.extractions).to be_empty
      expect(calls).to eq(1)
      expect(SeasonBoard::Scheduler).not_to have_received(:extract!)
    end

    it 'stops after 3 failed automatic attempts for the PDF' do
      3.times { |n| failed_extraction!(at: (n + 2).days.ago) }
      expect(plan.extractions).to be_empty
      expect(described_class.extraction_gave_up?(pdf)).to be true
    end

    it 'counts every automatic attempt not ended done: refused, and queued/running ones left stale by a dead worker' do
      failed_extraction!(at: 3.days.ago)
      FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'refused',
                                           created_at: 2.days.ago, updated_at: 2.days.ago)
      orphan = FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'running',
                                                    created_at: 1.day.ago)
      orphan.update_columns(updated_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
      FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'done', created_at: 4.days.ago)
      expect(described_class.unsuccessful_extractions(pdf)).to eq(3)
      expect(described_class.extraction_gave_up?(pdf)).to be true
      expect(plan.extractions).to be_empty
    end

    it 'does not count an attempt refused because a switch was off or unreadable (it never reached the engine)' do
      2.times { |n| failed_extraction!(at: (n + 2).days.ago) }
      FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'refused',
                                           error: 'automation_paused: automation paused', created_at: 1.day.ago)
      expect(described_class.unsuccessful_extractions(pdf)).to eq(2)
      expect(described_class.extraction_gave_up?(pdf)).to be false
      expect(plan.extractions).to eq([fin_id])
    end

    it 'does not count an attempt still running (not stale)' do
      FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-m.pdf', status: 'running')
      expect(described_class.unsuccessful_extractions(pdf)).to eq(0)
    end

    it 'gives up when the attempt count cannot be read (fail closed)' do
      allow(Ops::PipelineRun).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(described_class.extraction_gave_up?(pdf)).to be true
      expect(plan.extractions).to be_empty
    end

    it 'waits at least 20 hours after the last attempt' do
      failed_extraction!(at: 2.hours.ago)
      expect(plan.extractions).to be_empty
      Ops::PipelineRun.update_all(created_at: 21.hours.ago) # rubocop:disable Rails/SkipsModelValidations
      expect(plan.extractions).to eq([fin_id])
    end

    it 'queues no extraction with automation.auto_extract off' do
      DataFix::Automation.store!(:auto_extract, false)
      expect(plan.extractions).to be_empty
    end
  end
end
