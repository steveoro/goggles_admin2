# frozen_string_literal: true

require 'rails_helper'
require_relative 'cleanup/cleanup_fixtures'

# 0.10.104: the automatic tidy-up after a Sources crawl: only the board crawl rule (SeasonBoard::CrawlOutput) on the
# files this crawl run wrote, plus the calendar folder; nothing deleted, every move in MOVES.txt.
RSpec.describe Sources::CrawlTidy do
  include CleanupFixtures

  let(:data_dir) { File.realpath(Dir.mktmpdir('crawl-tidy-')) }
  let(:fin_id) { '150091' }
  let(:since) { 5.minutes.ago.change(usec: 0) }
  let(:own_key) { 'src:own' }
  let(:new_files) { [] }

  # (a new one per run: a Safety reads the activity log and the ops facts once)
  def safety = Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, own_key:, crawl_slot: true, crawler_status: crawler_idle)

  def tidy(kind: 'calendar_results', files: new_files)
    described_class.new(kind:, season_id: 262, new_files: files, since:, data_root: data_dir, own_key:, safety:,
                        db_index: db_index_linking(fin_id)).call
  end

  def rel(path) = Pathname.new(path).relative_path_from(Pathname.new(data_dir)).to_s

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    SeasonBoard::ActivityLog.new.start!(own_key, kind: :crawl, label: 'calendar results') # (the calling job's own entry)
  end

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  context 'when a calendar results crawl ended' do
    # (an older LT2 of the same FIN id: never touched, the tree checks prove it)
    before(:each) { age!(write_json('results.new', 'old.json', lt2_hash(fin_id:)), 2.hours.ago) }

    let!(:fresh_lt2) { write_json('results.new', 'm.json', lt2_hash(fin_id:)) }
    let!(:fresh_pdf) { write_file('manifests', 'manifest-m.pdf', '%PDF') }
    let!(:unlinked) { write_json('results.new', 'u.json', lt2_hash(fin_id: '150092')) }
    let!(:leftover) { old_file('calendar.new', '20261025-262-3-FIN-current-meetings-skip.csv', 'x') }
    let(:new_files) { [fresh_lt2, fresh_pdf, unlinked] }

    it 'moves only the files of the run: the result-free LT2 of the linked meeting, its manifest, the calendar leftover' do
      before = tree
      report = tidy
      expect(report).to have_attributes(refused: nil, moved: [fresh_lt2], backup_dir: start_with('results.backup/262/cleanup-'),
                                        archived: [path_for('manifests.done', 'manifest-m.pdf')], calendar: [leftover], moves: 3)
      # (old.json is older than the crawl, u.json is not linked: they stay)
      expect_only_moves(before, tree, rel(fresh_lt2) => "#{report.backup_dir}/m.json", rel(fresh_pdf) => 'manifests.done/262/manifest-m.pdf',
                                      rel(leftover) => "calendar.done/262/#{File.basename(leftover)}")
    end

    it 'never takes a fresh file the run did not write itself (not in its own listing)' do
      before = tree
      report = tidy(files: [unlinked]) # (m.json and its PDF changed during the run, but not by this crawl)
      expect(report.moved).to be_empty
      expect_only_moves(before, tree, rel(leftover) => "calendar.done/262/#{File.basename(leftover)}")
    end

    it 'keeps a truncated (unparsable) LT2: it may hold results' do
      File.write(fresh_lt2, %({"layoutType":2,"meetingURL":"#{results_url(fin_id)}","sections":[{"title":"50 SL","rows":[{"name":"ROSSI))
      before = tree
      report = tidy
      expect(report.moved).to be_empty
      expect(File).to exist(fresh_lt2)
      expect(tree.slice(rel(fresh_lt2))).to eq(before.slice(rel(fresh_lt2)))
    end

    it 'skips a whole FIN id with a busy activity, a pending run keyed by it or a leased base' do
      SeasonBoard::ActivityLog.new.queue!(fin_id, kind: :prepare, origin: :auto)
      expect(tidy.skipped).to include(["FIN #{fin_id}", :busy_activity])
      SeasonBoard::ActivityLog.new.finish!(fin_id, kind: :prepare, status: :done)

      run = Ops::PipelineRun.create!(subject_key: fin_id, kind: 'extract', origin: 'auto', status: 'running')
      expect(tidy.skipped).to include(["FIN #{fin_id}", :prepare_busy])
      run.update!(status: 'done')

      FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'old', lease_owner: 'job:9', lease_expires_at: 5.minutes.from_now)
      expect(tidy.skipped).to include(["FIN #{fin_id}", :leased])
      expect([fresh_lt2, fresh_pdf]).to all(satisfy { |path| File.exist?(path) })
    end

    it 'refuses the whole run while another crawl is running; a queued one cannot start before this job ends' do
      SeasonBoard::ActivityLog.new.start!('src:other', kind: :crawl, label: 'other')
      expect(tidy).to have_attributes(refused: :crawl_busy, moved: [], calendar: [])
      expect([fresh_lt2, leftover]).to all(satisfy { |path| File.exist?(path) })

      SeasonBoard::ActivityLog.new.queue!('src:other', kind: :crawl, origin: :manual, label: 'other')
      expect(tidy).to have_attributes(refused: nil, moved: [fresh_lt2])
    end

    it 'skips the season while an apply of the clean-up page holds its lock' do
      Sources::Cleanup::ApplyLock.lock_dir = data_dir
      Sources::Cleanup::ApplyLock.new(262).synchronize { expect(tidy.refused).to eq(:cleanup_running) }
      expect(File).to exist(fresh_lt2)
    ensure
      Sources::Cleanup::ApplyLock.lock_dir = nil
    end

    it 'does nothing when the activity log or the ops DB cannot be read' do
      File.write(SeasonBoard::ActivityLog.default_path, '{ broken')
      expect(tidy.refused).to eq(:activity_unreadable)
      FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
      allow(Ops).to receive(:available?).and_return(false)
      expect(tidy.refused).to eq(:ops_unavailable)
      expect([fresh_lt2, fresh_pdf, leftover]).to all(satisfy { |path| File.exist?(path) })
    end

    it 'leaves the other crawl kinds alone' do
      before = tree
      expect(tidy(kind: 'microplus')).to have_attributes(moved: [], calendar: [], refused: nil)
      expect(tree).to eq(before)
    end
  end

  describe '.after_crawl' do
    let(:request) { Sources::CrawlRequest.from(kind: 'calendar', season_id: 262) }

    it 'appends the summary of the tidy-up to the end message' do
      leftover = old_file('calendar.new', '20261025-262-3-FIN-current-meetings-skip.csv', 'x')
      allow(Sources::Cleanup::Safety).to receive(:new).and_return(safety)
      message = described_class.after_crawl(request, new_files: [], since:, data_root: data_dir, own_key:, message: 'Crawl done.')
      expect(message).to eq("Crawl done. #{I18n.t('sources.cleanup.crawl_summary.prefix', parts: I18n.t('sources.cleanup.crawl_summary.calendar', count: 1))}")
      expect(File).not_to exist(leftover)
    end

    it 'never raises: a failing tidy-up returns the message unchanged' do
      allow(Sources::Cleanup::Safety).to receive(:new).and_raise(Errno::EACCES, 'denied')
      expect(described_class.after_crawl(request, new_files: [], since:, data_root: data_dir, own_key:, message: 'Crawl done.')).to eq('Crawl done.')
    end
  end
end
