# frozen_string_literal: true

require 'rails_helper'
require_relative 'cleanup_fixtures'

# 0.10.104: the dry run of the clean-up page. One example per rule and one per refusal; nothing is ever written.
RSpec.describe Sources::Cleanup::Plan do
  include CleanupFixtures
  include ActiveSupport::Testing::TimeHelpers

  let(:data_dir) { File.realpath(Dir.mktmpdir('cleanup-plan-')) }
  let(:fin_id) { '150091' }
  let(:linked_ids) { [fin_id] }
  let(:crawler_status) { crawler_idle }
  let(:safety) { Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, crawler_status:) }
  let(:plan) { described_class.new(season_id: 262, data_root: data_dir, safety:, db_index: db_index_linking(*linked_ids)) }
  let(:backup) { 'results.backup/262/cleanup-<timestamp>' }

  def item_for(name) = plan.items.find { |item| File.basename(item.path) == name }
  def refusal_for(name) = plan.refusals.find { |refusal| File.basename(refusal.path) == name }

  # A result-free LT2 of the linked meeting (rule (a)).
  def result_free!(name = 'm.json', fin: fin_id) = old_json('results.new', name, lt2_hash(fin_id: fin))

  before(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  describe 'the rules' do
    it '(a) moves a result-free LT2 of a linked meeting with no LT4 and no phase files to the run backup folder' do
      result_free!
      expect(item_for('m.json')).to have_attributes(action: :move, rule: :result_free_source, fin_event_id: fin_id,
                                                    relative: 'results.new/262/m.json', destination: "#{backup}/m.json")
      expect(plan.refusals).to be_empty
      expect(plan).to be_applicable
    end

    it '(b) archives a pending manifest PDF (with its .txt) of a linked meeting to manifests.done' do
      old_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      old_file('manifests', 'manifest-m.pdf', '%PDF')
      old_file('manifests', 'manifest-m.txt', 'text')
      expect(item_for('manifest-m.pdf')).to have_attributes(action: :archive, rule: :pending_manifest, duplicate: false,
                                                            destination: 'manifests.done/262/manifest-m.pdf',
                                                            companion: 'manifests/262/manifest-m.txt')
      expect(item_for('m.json')).to be_nil # (it carries results: Data-Fix needs it)
    end

    it '(c) moves the superseded calendar originals, the finished selections and the -skip leftovers to calendar.done' do
      old_file('calendar.new', '20261025-262-3-FIN-current-meetings.csv', 'a')
      old_file('calendar.new', '20261109-262-3-FIN-current-meetings.csv', 'b')
      old_file('calendar.new', '20261109-262-3-FIN-current-meetings-sel-20261109-101010-123.csv', 'c')
      old_file('calendar.new', '20261109-262-3-FIN-current-meetings-sel-20261109-101010-123-skip.csv', 'd')
      rules = plan.move_items.to_h { |item| [File.basename(item.path), [item.rule, item.destination]] }
      expect(rules).to eq(
        '20261025-262-3-FIN-current-meetings.csv' => [:calendar_superseded, 'calendar.done/262/20261025-262-3-FIN-current-meetings.csv'],
        '20261109-262-3-FIN-current-meetings-sel-20261109-101010-123.csv' =>
          [:calendar_selection, 'calendar.done/262/20261109-262-3-FIN-current-meetings-sel-20261109-101010-123.csv'],
        '20261109-262-3-FIN-current-meetings-sel-20261109-101010-123-skip.csv' =>
          [:calendar_leftover, 'calendar.done/262/20261109-262-3-FIN-current-meetings-sel-20261109-101010-123-skip.csv']
      )
    end

    it '(d) only lists the duplicate bases of one FIN id and the result PDFs' do
      old_json('results.new', 'a.json', lt2_hash(fin_id: '150092', results: true))
      old_json('results.new', 'b.json', lt2_hash(fin_id: '150092', results: true))
      old_file('pdfs', 'results-x.pdf', '%PDF')
      expect(plan.list_items.map { |item| [File.basename(item.path), item.rule, item.action, item.destination] }).to contain_exactly(
        ['a.json', :duplicate_bases, :list_only, nil], ['b.json', :duplicate_bases, :list_only, nil], ['results-x.pdf', :result_pdf, :list_only, nil]
      )
      expect(plan.move_items).to be_empty
      expect(plan).not_to be_applicable
    end

    it 'never moves the newest original of a kind: the Eventi calendar stays the one SeasonBoard::CalendarIndex reads' do
      old_file('calendar.new', '20261101-262-2-FIN-calendar.csv', 'older')
      newest = old_file('calendar.new', '20261125-262-2-FIN-calendar.csv', 'newest')
      read_before = SeasonBoard::CalendarIndex.candidate_paths(262, data_dir:).first
      expect(plan.move_items.map { |item| File.basename(item.path) }).to eq(['20261101-262-2-FIN-calendar.csv'])

      before = tree
      result = Sources::Cleanup::Apply.new(season_id: 262, digest: plan.digest, data_root: data_dir, plan:,
                                           safety_options: { crawler_status: crawler_idle }).call
      expect(result).to be_done
      expect(read_before.to_s).to eq(newest)
      expect(SeasonBoard::CalendarIndex.candidate_paths(262, data_dir:).first.to_s).to eq(newest)
      expect_only_moves(before, tree, 'calendar.new/262/20261101-262-2-FIN-calendar.csv' => 'calendar.done/262/20261101-262-2-FIN-calendar.csv')
    end
  end

  describe 'the refusals' do
    it 'keeps a .sql sibling of a moved LT2 (the Outbox owns it)' do
      result_free!
      old_file('results.new', '0042-m-lt4.sql', 'SELECT 1;')
      expect(item_for('m.json')).to be_present
      expect(refusal_for('0042-m-lt4.sql')).to have_attributes(reason: :sql_file, rule: :result_free_source)
    end

    it 'keeps a file whose real path is in results.done' do
      done = old_json('results.done', 'm.json', lt2_hash(fin_id:))
      FileUtils.mkdir_p(File.join(data_dir, 'results.new/262'))
      File.symlink(done, path_for('results.new', 'm.json'))
      expect(refusal_for('m.json')).to have_attributes(reason: :archive_folder)
      expect(plan.move_items).to be_empty
    end

    it 'keeps the LT2 of a base having phase files' do
      result_free!
      old_json('results.new', 'm-lt4-phase1.json', { 'data' => {} })
      expect(refusal_for('m.json')).to have_attributes(reason: :phase_files)
    end

    it 'keeps the LT2 of a base having an LT4 working copy (and its manifest)' do
      result_free!
      old_json('results.new', 'm-lt4.json', lt4_hash(fin_id:))
      old_file('manifests', 'manifest-m.pdf', '%PDF')
      expect(refusal_for('m.json')).to have_attributes(reason: :lt4_working_copy)
      expect(refusal_for('manifest-m.pdf')).to have_attributes(reason: :lt4_working_copy)
    end

    it 'keeps a source recording operator edits' do
      result_free!
      source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', stage: 'new')
      FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase: 1, status: 'clean', checked_at: Time.current,
                                            operator_edited_at: Time.current)
      expect(refusal_for('m.json')).to have_attributes(reason: :edited)
    end

    it 'keeps a source in review' do
      result_free!
      FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', stage: 'needs_review')
      expect(refusal_for('m.json')).to have_attributes(reason: :in_review)
    end

    it 'keeps a leased source' do
      result_free!
      FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', stage: 'new', lease_owner: 'job:1', lease_expires_at: 5.minutes.from_now)
      expect(refusal_for('m.json')).to have_attributes(reason: :leased)
    end

    it 'keeps every file of a FIN id with a queued or running activity' do
      result_free!
      old_file('manifests', 'manifest-m.pdf', '%PDF')
      SeasonBoard::ActivityLog.new.queue!(fin_id, kind: :extract, origin: :auto)
      expect([refusal_for('m.json'), refusal_for('manifest-m.pdf')].map(&:reason)).to eq(%i[busy_activity busy_activity])
    end

    it 'keeps the manifest of a meeting that is not linked (the pending input of the extraction)' do
      old_json('results.new', 'm.json', lt2_hash(fin_id: '150093'))
      old_file('manifests', 'manifest-m.pdf', '%PDF')
      old_file('manifests', 'manifest-orphan.pdf', '%PDF')
      expect(refusal_for('manifest-m.pdf')).to have_attributes(reason: :unlinked_meeting, fin_event_id: '150093')
      expect(refusal_for('manifest-orphan.pdf')).to have_attributes(reason: :unlinked_meeting, fin_event_id: nil)
      expect(item_for('m.json')).to be_nil
    end

    it 'keeps a file younger than 10 minutes' do
      write_json('results.new', 'm.json', lt2_hash(fin_id:))
      write_file('calendar.new', '20261109-262-3-FIN-current-meetings-skip.csv', 'x')
      expect(plan.refusals.map(&:reason)).to eq(%i[too_recent too_recent])
    end

    it 'refuses the whole run while the crawler is busy' do
      result_free!
      expect(described_class.new(season_id: 262, data_root: data_dir, db_index: db_index_linking(fin_id),
                                 safety: Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, crawler_status: crawler_running)))
        .to have_attributes(blocked_reason: :crawler_busy, applicable?: false)
    end

    it 'refuses the whole run while any crawl is queued or running' do
      result_free!
      SeasonBoard::ActivityLog.new.queue!('src:abc', kind: :crawl, origin: :manual, label: 'calendar')
      expect(plan).to have_attributes(blocked_reason: :crawl_busy, applicable?: false)
    end

    it 'keeps a file whose real path is outside the data root' do
      outside = File.join(File.realpath(Dir.mktmpdir('cleanup-outside-')), 'm.json')
      File.write(outside, JSON.generate(lt2_hash(fin_id:)))
      FileUtils.mkdir_p(File.join(data_dir, 'results.new/262'))
      File.symlink(outside, path_for('results.new', 'm.json'))
      expect(refusal_for('m.json')).to have_attributes(reason: :outside)
    ensure
      FileUtils.rm_rf(File.dirname(outside)) if outside
    end

    it 'keeps an LT2 that cannot be parsed (truncated: it may hold results)' do
      old_file('results.new', 'm.json', %({"layoutType":2,"meetingURL":"#{results_url(fin_id)}","sections":[{"rows":[{"name":"RO))
      expect(refusal_for('m.json')).to have_attributes(reason: :unreadable_json, fin_event_id: fin_id)
      expect(plan.move_items).to be_empty
    end

    it 'keeps an LT2 written by the PDF scan (a ranking or stats section), even with a FIN URL typed in' do
      old_json('results.new', 'm-res.json', lt2_hash(fin_id:).merge('sections' => [{ 'title' => 'Classifica', 'ranking' => true, 'rows' => [] }]))
      expect(refusal_for('m-res.json')).to have_attributes(reason: :pdf_derived)
    end

    it 'keeps an LT2 modified after the end of its latest crawl (an edit in the file editor)' do
      lt2 = result_free!
      travel_to(30.minutes.ago) do
        SeasonBoard::ActivityLog.new.start!(fin_id, kind: :crawl)
        SeasonBoard::ActivityLog.new.finish!(fin_id, kind: :crawl, status: :done)
      end
      age!(lt2, 40.minutes.ago) # (written by the crawl)
      expect(item_for('m.json')).to be_present
      age!(lt2, 20.minutes.ago) # (changed after the crawl ended)
      expect(described_class.new(season_id: 262, data_root: data_dir, safety: Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir,
                                                                                                           crawler_status: crawler_idle),
                                 db_index: db_index_linking(fin_id)).refusals.map(&:reason)).to eq([:modified_after_crawl])
    end

    it 'does not mistake for an edit an LT2 written by a later Sources crawl that left no entry under the FIN id' do
      lt2 = result_free!
      travel_to(2.hours.ago) do
        SeasonBoard::ActivityLog.new.start!(fin_id, kind: :crawl)
        SeasonBoard::ActivityLog.new.finish!(fin_id, kind: :crawl, status: :done)
      end
      travel_to(40.minutes.ago) { SeasonBoard::ActivityLog.new.start!('src:csv', kind: :crawl, label: 'calendar CSV') }
      travel_to(25.minutes.ago) { SeasonBoard::ActivityLog.new.finish!('src:csv', kind: :crawl, status: :done) }
      age!(lt2, 30.minutes.ago) # (written during the CSV crawl)
      expect(item_for('m.json')).to be_present
    end

    it 'keeps every file of a FIN id with a pending run keyed by it' do
      result_free!
      Ops::PipelineRun.create!(subject_key: fin_id, kind: 'extract', origin: 'auto', status: 'queued')
      expect(refusal_for('m.json')).to have_attributes(reason: :prepare_busy)
    end

    it 'keeps a symlink pointing to another file of the data root' do
      real = old_json('calendar.new', 'target.json', lt2_hash(fin_id:)) # (a cleanable folder: only the link itself is refused)
      FileUtils.mkdir_p(File.join(data_dir, 'results.new/262'))
      File.symlink(real, path_for('results.new', 'm.json'))
      expect(refusal_for('m.json')).to have_attributes(reason: :symlink)
      expect(plan.move_items.map(&:relative)).not_to include('results.new/262/m.json', 'calendar.new/262/target.json')
    end

    it 'keeps a file Sources::FilePolicy refuses (a read-only folder)' do
      old_path = File.join(data_dir, 'results.old/262/m.json')
      FileUtils.mkdir_p(File.dirname(old_path))
      File.write(old_path, JSON.generate(lt2_hash(fin_id:)))
      FileUtils.mkdir_p(File.join(data_dir, 'results.new/262'))
      File.symlink(old_path, path_for('results.new', 'm.json'))
      expect(refusal_for('m.json')).to have_attributes(reason: :file_policy)
    end

    it 'sends an identical copy already at the destination to the duplicates folder' do
      old_file('manifests', 'manifest-m.pdf', '%PDF same')
      old_file('manifests.done', 'manifest-m.pdf', '%PDF same')
      old_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      expect(item_for('manifest-m.pdf')).to have_attributes(action: :archive, duplicate: true,
                                                            destination: "#{backup}/duplicates/manifests/manifest-m.pdf")
    end

    it 'keeps a file whose name is taken at the destination by a different content' do
      old_file('manifests', 'manifest-m.pdf', '%PDF new')
      old_file('manifests.done', 'manifest-m.pdf', '%PDF old')
      old_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
      expect(refusal_for('manifest-m.pdf')).to have_attributes(reason: :name_collision)
      expect(item_for('manifest-m.pdf')).to be_nil
    end
  end

  describe '#digest' do
    it 'is stable for the same files and changes with them' do
      result_free!
      first = plan.digest
      expect(described_class.new(season_id: 262, data_root: data_dir, safety:, db_index: db_index_linking(fin_id)).digest).to eq(first)
      result_free!('n.json')
      expect(described_class.new(season_id: 262, data_root: data_dir, safety:, db_index: db_index_linking(fin_id)).digest).not_to eq(first)
    end
  end

  it 'writes nothing' do
    result_free!
    old_file('manifests', 'manifest-m.pdf', '%PDF')
    old_file('calendar.new', '20261109-262-3-FIN-current-meetings-skip.csv', 'x')
    before = tree
    plan.items && plan.refusals && plan.digest
    expect(tree).to eq(before) # (same files, same content)
  end
end
