# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::Reconciler do
  include ActiveSupport::Testing::TimeHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  def reconcile(**options)
    described_class.call(data_root:, **options)
  end

  def row_at(rel_path)
    Ops::SqlScript.find_by(rel_path:)
  end

  describe 'unknown files' do
    it 'adopts a file dropped in results.new as pending, with the inferred kind and unknown local apply' do
      write_sql_file(data_root, 'results.new/262/0012-merge_teams-1-2.sql')
      report = reconcile
      expect(report.counts).to eq('pending' => 1)
      expect(row_at('results.new/262/0012-merge_teams-1-2.sql'))
        .to have_attributes(state: 'pending', kind: 'merge', folder: '262', season_id: 262, applied_locally: nil)
    end

    it 'holds an adopted normalize or standard timings script as not applied locally' do
      write_sql_file(data_root, 'results.new/normalize/0002-normalize_coded_names.sql')
      reconcile
      expect(row_at('results.new/normalize/0002-normalize_coded_names.sql'))
        .to have_attributes(state: 'held', held_reason: 'not_applied_locally', applied_locally: false, kind: 'normalize')
    end

    it 'registers an unknown file in results.sent as legacy_sent' do
      write_sql_file(data_root, 'results.sent/252/0300-a-lt4.sql')
      reconcile
      expect(row_at('results.sent/252/0300-a-lt4.sql')).to have_attributes(state: 'legacy_sent', kind: 'commit')
    end

    it 'holds an unknown file of a legacy folder (redo, old-subseeded)' do
      write_sql_file(data_root, 'redo/0178-merge_teams-1605-478.sql')
      write_sql_file(data_root, 'results.new/old-subseeded/019-datafix-rename.sql')
      reconcile
      expect(row_at('redo/0178-merge_teams-1605-478.sql')).to have_attributes(state: 'held', held_reason: 'legacy_folder', folder: 'redo')
      expect(row_at('results.new/old-subseeded/019-datafix-rename.sql')).to have_attributes(state: 'held', held_reason: 'legacy_folder')
    end

    it 'gives new pending scripts the next seq, in file-prefix order' do
      write_sql_file(data_root, 'results.sent/262/0476-a-lt4.sql')
      write_sql_file(data_root, 'results.new/misc/0480-merge_teams-1-2.sql')
      write_sql_file(data_root, 'results.new/262/0478-b-lt4.sql', "SELECT 2;\r\n")
      reconcile
      expect(row_at('results.new/262/0478-b-lt4.sql').seq).to eq(481)
      expect(row_at('results.new/misc/0480-merge_teams-1-2.sql').seq).to eq(482)
      expect(row_at('results.sent/262/0476-a-lt4.sql').seq).to be < 481
    end

    it 'never scans results.done, results.backup, results.old or results.new/discarded' do
      %w[results.done/262/0001-a-lt4.sql results.done.2025/262/0002-b-lt4.sql results.backup/0003-c.sql
         results.old/0004-d.sql results.new/discarded/262/0005-e-lt4.sql].each_with_index do |rel_path, index|
        write_sql_file(data_root, rel_path, "SELECT #{index};")
      end
      expect(reconcile.scanned).to eq(0)
      expect(Ops::SqlScript.count).to eq(0)
    end
  end

  describe 'registered files' do
    it 'changes nothing on a second run' do
      write_sql_file(data_root, 'results.new/262/0012-merge_teams-1-2.sql')
      write_sql_file(data_root, 'results.sent/262/0010-a-lt4.sql', 'SELECT 3;')
      reconcile
      report = reconcile
      expect(report.counts).to eq('unchanged' => 2)
      expect(report).not_to be_changed
    end

    it 're-hashes an edited pending file' do
      script = create_sql_script(data_root, 'results.new/262/0012-a-lt4.sql')
      travel_to(1.minute.from_now) { File.write(script.absolute_path, 'SELECT 42;') }
      expect(reconcile.counts).to eq('rehashed' => 1)
      expect(script.reload).to have_attributes(sha256: Digest::SHA256.hexdigest('SELECT 42;'), changed_after_push: false)
    end

    it 'flags an edited sent or legacy file as changed after push' do
      script = create_sql_script(data_root, 'results.sent/262/0010-a-lt4.sql', state: 'sent')
      travel_to(1.minute.from_now) { File.write(script.absolute_path, 'SELECT 42;') }
      expect(reconcile.counts).to eq('changed_after_push' => 1)
      expect(script.reload).to have_attributes(state: 'sent', changed_after_push: true)
    end

    it 'marks a gone file as missing and restores its state when it reappears' do
      script = create_sql_script(data_root, 'results.new/262/0012-a-lt4.sql', state: 'held', held_reason: 'operator')
      content = File.binread(script.absolute_path)
      FileUtils.rm(script.absolute_path)
      expect(reconcile.counts).to eq('missing' => 1)
      expect(script.reload).to have_attributes(state: 'missing', previous_state: 'held')

      File.binwrite(script.absolute_path, content)
      expect(reconcile.counts).to eq('reappeared' => 1)
      expect(script.reload).to have_attributes(state: 'held', previous_state: nil)
    end

    it 'follows a file moved by hand from results.new to results.sent (legacy_sent + event)' do
      script = create_sql_script(data_root, 'results.new/262/0012-a-lt4.sql')
      FileUtils.mkdir_p(data_root.join('results.sent/262'))
      FileUtils.mv(script.absolute_path, data_root.join('results.sent/262/0012-a-lt4.sql'))
      expect(reconcile.counts).to eq('moved_to_sent' => 1)
      expect(script.reload).to have_attributes(state: 'legacy_sent', rel_path: 'results.sent/262/0012-a-lt4.sql')
      expect(Ops::Event.last).to have_attributes(kind: 'outbox.moved_by_hand', subject_key: script.id.to_s)
    end

    it 'follows a sent file moved back to results.new (pending, changed after push)' do
      script = create_sql_script(data_root, 'results.sent/262/0012-a-lt4.sql', state: 'sent', remote_iq_id: 9)
      FileUtils.mkdir_p(data_root.join('results.new/262'))
      FileUtils.mv(script.absolute_path, data_root.join('results.new/262/0012-a-lt4.sql'))
      expect(reconcile.counts).to eq('moved_back' => 1)
      expect(script.reload).to have_attributes(state: 'pending', changed_after_push: true, rel_path: 'results.new/262/0012-a-lt4.sql')
    end

    it 'leaves the discarded scripts alone' do
      create_sql_script(data_root, 'results.new/discarded/262/0012-a-lt4.sql', state: 'discarded', note: 'dup')
      expect(reconcile.counts).to eq({})
    end

    it 'turns a stale pushing script into in_doubt, unless a push run is live' do
      script = create_sql_script(data_root, 'results.new/262/0012-a-lt4.sql', state: 'pushing')
      travel_to(11.minutes.from_now) do
        live_run = Ops::PushRun.create!(status: 'running', script_ids: [script.id], started_at: Time.current)
        expect(reconcile.counts).to eq('unchanged' => 1)
        live_run.update!(status: 'stopped')
        expect(reconcile.counts).to include('in_doubt' => 1)
      end
      expect(script.reload).to be_in_doubt
    end
  end

  describe 'import mode' do
    before(:each) do
      write_sql_file(data_root, 'results.sent/262/0476-a-lt4.sql', 'SELECT 1;')
      write_sql_file(data_root, 'results.sent/misc/0100-merge_teams-1-2.sql', 'SELECT 2;')
      write_sql_file(data_root, 'results.new/old-subseeded/017-232-standard_timings.sql', 'SELECT 3;')
      write_sql_file(data_root, 'redo/0178-merge_teams-1605-478.sql', 'SELECT 4;')
      write_sql_file(data_root, 'results.new/normalize/0002-normalize_coded_names.sql', 'SELECT 5;')
    end

    it 'reports the counts without writing anything when simulating' do
      report = reconcile(import: true, simulate: true)
      expect(report.counts).to eq('legacy_sent' => 2, 'archived' => 2, 'held' => 1)
      expect(Ops::SqlScript.count).to eq(0)
      expect(report.lines.first).to include('SIMULATE')
    end

    it 'simulates even when the ops DB is not available' do
      allow(Ops::Database).to receive(:state).and_return(:needs_migration)
      expect(reconcile(import: true, simulate: true).counts).to eq('legacy_sent' => 2, 'archived' => 2, 'held' => 1)
    end

    it 'archives the legacy folders, already registered or not' do
      reconcile # (regular run first: legacy folders held)
      expect(row_at('redo/0178-merge_teams-1605-478.sql')).to be_held
      report = reconcile(import: true)
      expect(report.counts).to include('archived' => 2)
      expect(Ops::SqlScript.in_state('archived').pluck(:note).uniq).to eq([described_class::ARCHIVE_NOTE])
      expect(row_at('results.new/normalize/0002-normalize_coded_names.sql')).to have_attributes(state: 'held', applied_locally: false)
    end

    it 'never touches the files' do
      before = Dir.glob(data_root.join('**', '*').to_s)
      reconcile(import: true)
      expect(Dir.glob(data_root.join('**', '*').to_s)).to eq(before)
    end
  end

  describe '.call_throttled' do
    it 'runs at most once every 30 seconds' do
      write_sql_file(data_root, 'results.new/262/0012-merge_teams-1-2.sql')
      expect(described_class.call_throttled(data_root:)).to be_a(described_class::Report)
      expect(described_class.call_throttled(data_root:)).to be_nil
      travel_to(31.seconds.from_now) { expect(described_class.call_throttled(data_root:)).to be_a(described_class::Report) }
    end
  end

  it 'skips the run (no write) when the ops DB is not available' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    write_sql_file(data_root, 'results.new/262/0012-merge_teams-1-2.sql')
    expect(reconcile.skipped).to include('missing')
  end

  it 'is registered as the :outbox rebuilder' do
    expect(Ops::Rebuilders.names).to include(:outbox)
  end
end
