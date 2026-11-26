# frozen_string_literal: true

require 'rails_helper'
require_relative '../sources/cleanup/cleanup_fixtures'

# 0.10.104: the board crawl tidy-up (shared with Sources::CrawlTidy): only the files the crawl run wrote, behind the
# Sources::Cleanup::Safety checks, never raising.
RSpec.describe SeasonBoard::CrawlOutput do
  include CleanupFixtures

  let(:data_dir) { File.realpath(Dir.mktmpdir('crawl-output-')) }
  let(:fin_id) { '150091' }
  let(:since) { 5.minutes.ago.change(usec: 0) }
  let!(:lt2) { write_json('results.new', 'm.json', lt2_hash(fin_id:)) }
  let!(:pdf) { write_file('manifests', 'manifest-m.pdf', '%PDF') }
  let(:new_files) { [lt2, pdf] }

  # (the board crawl's own entry: running under the FIN id)
  def output(files: new_files, until_time: nil, safety: nil)
    described_class.new(season_id: 262, fin_event_id: fin_id, since:, data_dir:, db_index: db_index_linking(fin_id), new_files: files,
                        until_time:, own_key: fin_id,
                        safety: safety || Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, own_key: fin_id, crawl_slot: true,
                                                                       crawler_status: crawler_idle)).call
  end

  def rel(path) = Pathname.new(path).relative_path_from(Pathname.new(data_dir)).to_s

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    SeasonBoard::ActivityLog.new.start!(fin_id, kind: :crawl)
  end

  after(:each) do
    Sources::Cleanup::ApplyLock.lock_dir = nil
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it "moves the run's own redundant LT2 and manifest, lists both moves in MOVES.txt and changes nothing else" do
    before = tree
    result = output
    expect(result).to have_attributes(status: :done, message: 'no results yet (redundant crawl output moved to results.backup)', moves: 2,
                                      backup_dir: start_with('results.backup/262/cleanup-'))
    expect_only_moves(before, tree, rel(lt2) => "#{result.backup_dir}/m.json", rel(pdf) => 'manifests.done/262/manifest-m.pdf')
  end

  describe 'only the files of this run' do
    it 'keeps a fresh file missing from the run listing, or changed after the run ended' do
      before = tree
      expect(output(files: []).removed).to be_empty
      expect(output(until_time: 1.minute.ago).removed).to be_empty
      expect(tree).to eq(before)
    end

    it 'keeps an unparsable (truncated) LT2' do
      File.write(lt2, %({"layoutType":2,"meetingURL":"#{results_url(fin_id)}","sections":[{"rows":[{"name":"RO))
      before = tree
      expect(output).to have_attributes(status: :done, removed: [])
      expect(tree.slice(rel(lt2))).to eq(before.slice(rel(lt2)))
    end
  end

  describe 'the Safety checks on the board path' do
    def skipped_reason = output.skipped.to_h["FIN #{fin_id}"]

    it 'does not count its own running crawl entry as busy' do
      expect(skipped_reason).to be_nil
    end

    it 'skips while another crawl runs, an apply holds the season, the ops DB or the activity log cannot be read' do
      SeasonBoard::ActivityLog.new.start!('src:other', kind: :crawl, label: 'other')
      expect(skipped_reason).to eq(:crawl_busy)
      SeasonBoard::ActivityLog.new.finish!('src:other', kind: :crawl, status: :done)
      Sources::Cleanup::ApplyLock.lock_dir = data_dir
      Sources::Cleanup::ApplyLock.new(262).synchronize { expect(skipped_reason).to eq(:cleanup_running) }
      allow(Ops).to receive(:available?).and_return(false)
      expect(skipped_reason).to eq(:ops_unavailable)
      allow(Ops).to receive(:available?).and_call_original
      File.write(SeasonBoard::ActivityLog.default_path, '{ broken')
      expect(skipped_reason).to eq(:activity_unreadable)
      expect([lt2, pdf]).to all(satisfy { |path| File.exist?(path) })
    end

    it 'skips a FIN id with a queued prepare (the "Prepare" of the operator) or extraction, or a pending run keyed by it' do
      SeasonBoard::ActivityLog.new.queue!(fin_id, kind: :prepare, origin: :manual)
      expect(skipped_reason).to eq(:busy_activity)
      SeasonBoard::ActivityLog.new.finish!(fin_id, kind: :prepare, status: :done)
      Ops::PipelineRun.create!(subject_key: 'manifest-m.pdf', kind: 'extract', origin: 'auto', status: 'queued')
      expect(skipped_reason).to eq(:prepare_busy)
      expect(File).to exist(lt2)
    end

    it 'skips a base that is leased, being prepared, edited or in review' do
      source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', lease_owner: 'job:1', lease_expires_at: 5.minutes.from_now)
      expect(skipped_reason).to eq(:leased)
      source.update!(lease_owner: nil, lease_expires_at: nil)
      Ops::PipelineRun.create!(pipeline_source: source, subject_key: 'm', kind: 'prepare', origin: 'operator', status: 'running')
      expect(skipped_reason).to eq(:prepare_busy)
      Ops::PipelineRun.update_all(status: 'done') # rubocop:disable Rails/SkipsModelValidations
      source.update!(stage: 'needs_review')
      expect(skipped_reason).to eq(:in_review)
      source.update!(stage: 'new')
      FactoryBot.create(:ops_phase_verdict, pipeline_source: source, operator_edited_at: Time.current)
      expect(skipped_reason).to eq(:edited)
      expect(File).to exist(lt2)
    end
  end

  describe 'never raising' do
    it 'reports a failing move and keeps the crawl outcome' do
      allow_any_instance_of(Sources::Cleanup::Mover).to receive(:to_backup).and_raise(Errno::ENOSPC, 'full') # rubocop:disable RSpec/AnyInstance
      result = nil
      expect { result = output }.not_to raise_error
      expect(result).to have_attributes(status: :done, message: 'no results yet (clean-up stopped by an error)')
      expect(result.skipped.to_h["FIN #{fin_id}"]).to include('Errno::ENOSPC')
    end

    it 'answers :failed when the output itself cannot be read' do
      allow_any_instance_of(SeasonBoard::DiskIndex).to receive(:for).and_raise(Errno::EACCES, 'denied') # rubocop:disable RSpec/AnyInstance
      expect(output).to have_attributes(status: :failed, message: start_with('output check failed: Errno::EACCES'))
    end
  end
end
