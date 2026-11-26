# frozen_string_literal: true

require 'rails_helper'
require_relative 'disk_fixtures'

# Phase 10: the ops pipeline facts of a season, reconciled with the files on disk.
RSpec.describe SeasonBoard::PipelineIndex do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('pipeline-index') }
  let(:disk_index) { SeasonBoard::DiskIndex.new(season_id: 262, data_dir:) }
  let(:index) { described_class.new(season_id: 262) }
  let(:fin_id) { '150091' }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def source!(**attributes)
    FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', source_path: path_for('results.new', 'm-lt4.json'),
                                            db_generation: DataFix::Pipeline.db_generation, **attributes)
  end

  def verdicts!(source, checked_at: 2.seconds.from_now, **statuses)
    (1..5).each do |phase|
      FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, status: statuses.fetch(:"p#{phase}", 'clean'), checked_at:)
    end
  end

  def facts
    index.for_entry(disk_index.for(fin_id))
  end

  before(:each) { write_json('results.new', 'm-lt4.json', lt4_hash(fin_id:, results: true)) }

  it 'answers nil for files without an ops row (the board keeps the former states)' do
    expect(facts).to be_nil
  end

  it 'reports a clean, fresh source as ready to commit, with its new entities' do
    verdicts!(source!(stage: 'ready_to_commit', new_teams_count: 2, new_swimmers_count: 37))
    expect(facts).to have_attributes(stage: 'ready_to_commit', new_teams: 2, new_swimmers: 37, verdict_count: 5)
    expect(facts).to be_fresh
    expect(facts).to be_ready_to_commit
    expect(facts.state_and_detail).to eq([:ready_to_commit, { new_teams: 2, new_swimmers: 37 }])
  end

  it 'gives the board state of the facts (phase 15: Sources rows and non-FIN sources), preparing first' do
    source = source!(stage: 'needs_review', review_phase: 2, review_count: 4)
    verdicts!(source)
    expect(facts.state_and_detail).to eq([:needs_review, { step: 2, count: 4, blocked: false }])
    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', status: 'running', subject_key: 'm')
    expect(described_class.new(season_id: 262).for_entry(disk_index.for(fin_id)).state_and_detail).to eq([:preparing, {}])
  end

  it 'reads a queued prepare as :prepare_queued for a source without verdicts or whose last prepare failed' do
    source = source!(stage: 'new')
    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', status: 'queued', subject_key: 'm')
    expect(facts).to have_attributes(prepare_queued?: true, preparing?: false)
    expect(facts.state_and_detail).to eq([:prepare_queued, {}])

    source.update!(stage: 'failed')
    expect(described_class.new(season_id: 262).for_entry(disk_index.for(fin_id)).state_and_detail).to eq([:prepare_queued, {}])
    Ops::PipelineRun.update_all(status: 'running') # rubocop:disable Rails/SkipsModelValidations
    expect(described_class.new(season_id: 262).for_entry(disk_index.for(fin_id))).to have_attributes(prepare_queued?: false, preparing?: true)
  end

  it 'keeps the state while a prepare run is merely queued (0.10.99: only a running run or the lease is preparing)' do
    source = source!(stage: 'needs_review', review_phase: 2, review_count: 4)
    verdicts!(source)
    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', status: 'queued', subject_key: 'm')
    expect(facts).to have_attributes(preparing?: false, leased?: false, prepare_queued?: true)
    expect(facts.state_and_detail).to eq([:needs_review, { step: 2, count: 4, blocked: false }])
  end

  # 0.10.99: each verdict is compared with the files its cache fingerprint covers (working copy + phase files 1..N).
  describe 'freshness per verdict' do
    let(:base_time) { 1.hour.ago }

    # Phase files 1..3 written at base + 10 * N minutes, each verdict N checked one minute after its file (verdicts 4-5
    # after the last one); the LT4 working copy at the base time.
    def set_mtime(path, time) = File.utime(time.to_time, time.to_time, path)

    def prepared!(stage: 'ready_to_commit')
      set_mtime(path_for('results.new', 'm-lt4.json'), base_time)
      (1..3).each { |phase| set_mtime(write_json('results.new', "m-lt4-phase#{phase}.json", { 'data' => {} }), base_time + (10 * phase).minutes) }
      source = source!(stage:)
      (1..5).each do |phase|
        checked_at = base_time + ((10 * [phase, 3].min) + 1).minutes
        FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, status: 'clean', checked_at:)
      end
      source
    end

    def fresh_facts = described_class.new(season_id: 262).for_entry(disk_index.for(fin_id))

    it 'is fresh when each verdict is newer than its own files, even if the first one is older than the last file' do
      prepared!
      expect(Ops::PhaseVerdict.minimum(:checked_at)).to be < File.mtime(path_for('results.new', 'm-lt4-phase3.json'))
      expect(fresh_facts).to have_attributes(fresh?: true, ready_to_commit?: true)
      expect(fresh_facts.state_and_detail.first).to eq(:ready_to_commit)
      expect(fresh_facts.newest_file_at).to be_within(1.second).of(base_time + 30.minutes)
    end

    it 'stays fresh when only the LT2 is newer (a CSV crawl rewrites a same-named LT2: the LT4 working copy is the source)' do
      prepared!
      lt2 = write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      File.utime(Time.current.to_time, Time.current.to_time, lt2)
      expect(fresh_facts).to be_fresh
      Ops::PipelineSource.update_all(source_path: lt2) # rubocop:disable Rails/SkipsModelValidations -- as stored by a schedule from the LT2
      expect(fresh_facts).to be_fresh
    end

    it 'is not fresh when the phase 2 file is newer than its verdict, and then reads "checks outdated"' do
      prepared!
      later = (base_time + 25.minutes).to_time # (after its verdict at +21, before the phase 3 file)
      File.utime(later, later, path_for('results.new', 'm-lt4-phase2.json'))
      expect(fresh_facts).to have_attributes(fresh?: false, needs_review?: true, outdated?: true)
      state, detail = fresh_facts.state_and_detail
      expect([state, detail]).to eq([:needs_review, { step: 3, count: 0, blocked: false, outdated: true }])
      expect(SeasonBoard::StateText.label(state, detail)).to eq(I18n.t('season_board.state_details.outdated'))
    end

    it 'is not fresh when the working copy is newer than the verdicts' do
      prepared!
      File.utime(Time.current.to_time, Time.current.to_time, path_for('results.new', 'm-lt4.json'))
      expect(fresh_facts).not_to be_fresh
    end
  end

  it 'is not fresh when a file is newer than the verdicts, or the db generation moved under new entities' do
    verdicts!(source!(stage: 'ready_to_commit'), checked_at: 1.hour.ago)
    expect(facts).not_to be_fresh
    expect(facts).to be_needs_review

    Ops::PhaseVerdict.update_all(checked_at: 1.minute.from_now) # rubocop:disable Rails/SkipsModelValidations
    Ops::PipelineSource.update_all(new_teams_count: 1, db_generation: DataFix::Pipeline.db_generation - 1) # rubocop:disable Rails/SkipsModelValidations
    expect(described_class.new(season_id: 262).for_entry(disk_index.for(fin_id))).to have_attributes(db_behind?: true, fresh?: false)
  end

  it 'reports the stale phases, the recorded edits and the hold' do
    source = source!(stage: 'needs_review', review_phase: 2, auto_prepare: false)
    verdicts!(source, p2: 'stale')
    source.phase_verdicts.find_by(phase: 3).update!(operator_edited_at: Time.current)
    expect(facts).to have_attributes(stale_phases: [2], edited_recorded?: true, held?: true, review_step: 2)
  end

  it 'reports a failed prepare (unchanged source) and a source changed since' do
    source = source!(stage: 'failed', failed_source_sha256: Digest::SHA256.file(path_for('results.new', 'm-lt4.json')).hexdigest)
    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', origin: 'auto', status: 'failed', phase: 3,
                                         error: 'solver exploded', finished_at: 1.minute.from_now)
    expect(facts).to have_attributes(prepare_failed?: true, failed_phase: 3, failed_message: 'solver exploded')

    source.update!(failed_source_sha256: 'another')
    expect(described_class.new(season_id: 262).for_entry(disk_index.for(fin_id))).to have_attributes(prepare_failed?: false, failed_but_changed?: true)
  end

  it 'reports a source being prepared (job lease or running run), the lease as leased? (the board locks the links)' do
    source = source!(stage: 'preparing')
    source.acquire_lease!('job:abc', ttl: 5.minutes)
    expect(facts).to have_attributes(preparing?: true, leased?: true)
  end

  it 'answers nil without the ops DB' do
    allow(Ops).to receive(:available?).and_return(false)
    expect(facts).to be_nil
  end
end
