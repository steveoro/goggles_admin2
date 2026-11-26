# frozen_string_literal: true

require 'rails_helper'
require_relative 'cleanup_fixtures'

# 0.10.104: the operator's apply of the clean-up. Nothing is ever deleted: every file reaches its destination intact,
# nothing else in the data root changes, and every move is in MOVES.txt.
RSpec.describe Sources::Cleanup::Apply do
  include CleanupFixtures

  let(:data_dir) { File.realpath(Dir.mktmpdir('cleanup-apply-')) }
  let(:fin_id) { '150091' }
  let(:now) { Time.utc(2026, 11, 26, 10, 15, 0) }
  let(:safety) { Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, crawler_status: crawler_idle, holds_apply_lock: true) }
  let(:plan) { new_plan }
  let(:folder) { 'results.backup/262/cleanup-20261126-101500' }
  let!(:sources) do
    {
      lt2: old_json('results.new', 'm.json', lt2_hash(fin_id:)),
      pdf: old_file('manifests', 'manifest-m.pdf', '%PDF m'),
      txt: old_file('manifests', 'manifest-m.txt', 'manifest text'),
      dup: old_file('manifests', 'manifest-n.pdf', '%PDF n'),
      csv: old_file('calendar.new', '20261025-262-3-FIN-current-meetings.csv', 'old'),
      skip: old_file('calendar.new', '20261109-262-3-FIN-current-meetings-skip.csv', 'skip')
    }
  end

  def new_plan = Sources::Cleanup::Plan.new(season_id: 262, data_root: data_dir, safety:, db_index: db_index_linking(fin_id))

  def apply(digest: plan.digest, with_plan: plan)
    described_class.new(season_id: 262, digest:, data_root: data_dir, now:, plan: with_plan, safety_options: { crawler_status: crawler_idle }).call
  end

  def rel(path) = Pathname.new(path).relative_path_from(Pathname.new(data_dir)).to_s

  # Every move of the full plan, { from => to } (relative).
  def all_moves
    {
      rel(sources[:lt2]) => "#{folder}/m.json", 'results.new/262/n.json' => "#{folder}/n.json",
      rel(sources[:pdf]) => 'manifests.done/262/manifest-m.pdf', rel(sources[:txt]) => 'manifests.done/262/manifest-m.txt',
      rel(sources[:dup]) => "#{folder}/duplicates/manifests/manifest-n.pdf",
      rel(sources[:csv]) => 'calendar.done/262/20261025-262-3-FIN-current-meetings.csv',
      rel(sources[:skip]) => 'calendar.done/262/20261109-262-3-FIN-current-meetings-skip.csv'
    }
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    Sources::Cleanup::ApplyLock.lock_dir = File.join(data_dir, '..', "#{File.basename(data_dir)}-locks")
    old_file('calendar.new', '20261109-262-3-FIN-current-meetings.csv', 'newest')
    old_file('manifests.done', 'manifest-n.pdf', '%PDF n') # (an identical copy is already archived)
    old_json('results.new', 'n.json', lt2_hash(fin_id:)) # (same FIN id: 'manifest-n' belongs to the linked meeting)
    allow(SeasonBoard::Snapshot).to receive(:invalidate!)
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  after(:each) do
    FileUtils.rm_rf([data_dir, Sources::Cleanup::ApplyLock.lock_dir])
    Sources::Cleanup::ApplyLock.lock_dir = nil
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'moves exactly the files of the plan, each with the same content, changes nothing else, and lists every move' do
    plan.digest
    before = tree
    result = apply
    expect(result).to have_attributes(status: :done, error: nil, backup_dir: folder)
    expect_only_moves(before, tree, all_moves)
    expect(File).not_to exist(Sources::Cleanup::ApplyLock.path_for(262)) # (released)
  end

  it 'records the sources.cleanup_applied event with the counts and the backup folder, and refreshes the board' do
    apply
    event = Ops::Event.where(kind: described_class::EVENT_KIND).last
    expect(event).to have_attributes(level: 'success', actor: 'operator', season_id: 262, subject_key: folder)
    expect(event.data).to include('moved' => 2, 'archived' => 2, 'calendar' => 2, 'duplicates' => 1, 'skipped' => 0,
                                  'backup_dir' => folder, 'error' => nil)
    expect(event.title).to eq(I18n.t('ops.events.sources.cleanup_applied'))
    expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(262)
    expect(SeasonBoard::Notifier).to have_received(:ping)
  end

  it 'refuses a digest different from the one the operator saw (and moves nothing)' do
    seen = plan.digest
    old_json('results.new', 'later.json', lt2_hash(fin_id:))
    before = tree
    expect(apply(digest: seen, with_plan: new_plan)).to have_attributes(status: :refused, reason: :digest_mismatch)
    expect(tree).to eq(before)
    expect(Ops::Event.where(kind: described_class::EVENT_KIND)).to be_empty
  end

  it 'refuses while a crawl is running, and without the ops DB' do
    SeasonBoard::ActivityLog.new.start!('src:abc', kind: :crawl, label: 'calendar')
    before = tree
    expect(apply(with_plan: new_plan)).to have_attributes(status: :refused, reason: :crawl_busy)
    allow(Ops).to receive(:available?).and_return(false)
    expect(apply).to have_attributes(status: :refused, reason: :ops_unavailable)
    expect(tree).to eq(before)
  end

  describe 'concurrency' do
    it 'refuses a second apply of the season while one runs (lock), and runs once it is released' do
      digest = plan.digest
      before = tree
      Sources::Cleanup::ApplyLock.new(262).synchronize do
        expect(apply(digest:)).to have_attributes(status: :refused, reason: :apply_running)
      end
      expect(tree).to eq(before)
      expect(apply(digest:)).to be_done
    end

    it 'takes over a stale lock left by a killed run' do
      path = Sources::Cleanup::ApplyLock.path_for(262)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, 'killed')
      File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, path)
      expect(apply).to be_done
    end

    it 'gives two runs started in the same second two backup folders' do
      first = Sources::Cleanup::RunFolder.new(root: data_dir, season_id: 262, now:)
      second = Sources::Cleanup::RunFolder.new(root: data_dir, season_id: 262, now:)
      expect([first.path, second.path].map { |path| File.basename(path) }).to eq(%w[cleanup-20261126-101500 cleanup-20261126-101500-2])
    end

    it 'checks every item again right before moving it: an item that became busy is skipped and reported' do
      digest = plan.digest
      SeasonBoard::ActivityLog.new.queue!(fin_id, kind: :extract, origin: :auto) # (after the plan was shown)
      before = tree
      result = apply(digest:)
      expect(result.status).to eq(:done)
      expect(result.skipped.map { |outcome| [File.basename(outcome.from), outcome.reason] }).to contain_exactly(
        ['m.json', :busy_activity], ['n.json', :busy_activity], ['manifest-m.pdf', :busy_activity], ['manifest-n.pdf', :busy_activity]
      )
      expect_only_moves(before, tree, all_moves.select { |from, _to| from.start_with?('calendar.new/') })
    end
  end

  it 'stops at the first unexpected error, reports what moved before it, and its MOVES.txt already lists that move' do
    calls = 0
    allow(File).to receive(:link).and_wrap_original do |original, *args|
      calls += 1
      raise Errno::EIO, 'disk trouble' if calls == 2

      original.call(*args)
    end
    before = tree
    result = apply
    expect(result.status).to eq(:failed)
    expect(result.error).to include('Errno::EIO')
    expect(result.moved.size).to eq(1)
    expect_only_moves(before, tree, rel(sources[:lt2]) => "#{folder}/m.json")
    event = Ops::Event.where(kind: described_class::EVENT_KIND).last
    expect(event).to have_attributes(level: 'error')
    expect(event.data['error']).to include('disk trouble')
  end
end
