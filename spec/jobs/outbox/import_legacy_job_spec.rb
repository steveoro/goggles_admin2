# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::ImportLegacyJob do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  # A small copy of the real tree: sent scripts, pre-Outbox leftovers, the held normalize script, archives.
  before(:each) do
    write_sql_file(data_root, 'results.sent/262/0476-2026-11-08-Trofeo-lt4.sql', 'SELECT 1;')
    write_sql_file(data_root, 'results.sent/misc/0107-merge_badges-1-2.sql', 'SELECT 2;')
    write_sql_file(data_root, 'results.sent/goggle_cups/0003-cup.sql', 'SELECT 3;')
    write_sql_file(data_root, 'results.new/old-subseeded/007-20241009_171700-1-sure_merge_badges-season_192.sql', 'SELECT 4;')
    write_sql_file(data_root, 'redo/0180-merge_badges-214795-206552.sql', 'SELECT 5;')
    write_sql_file(data_root, 'results.new/normalize/0002-normalize_coded_names.sql', 'SELECT 6;')
    write_sql_file(data_root, 'results.done/252/0000-252-standard_timings.sql', 'SELECT 7;')
    write_sql_file(data_root, 'results.done.2025/252/0001-x-lt4.sql', 'SELECT 8;')
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'runs on the outbox queue' do
    expect(described_class.new.queue_name).to eq('outbox')
  end

  it 'simulates by default: counts only' do
    report = described_class.perform_now(data_root:)
    expect(report.counts).to eq('legacy_sent' => 3, 'archived' => 2, 'held' => 1)
    expect(Ops::SqlScript.count).to eq(0)
    expect(Ops::Setting.fetch(Outbox::Reconciler::IMPORTED_AT_KEY)).to be_nil
  end

  it 'registers the rows, stores the import time and records the event when applied' do
    report = described_class.perform_now(simulate: false, data_root:)
    expect(report.counts).to eq('legacy_sent' => 3, 'archived' => 2, 'held' => 1)
    expect(Ops::SqlScript.group(:state).count).to eq('legacy_sent' => 3, 'archived' => 2, 'held' => 1)
    expect(Ops::SqlScript.find_by(folder: 'goggle_cups').kind).to eq('goggle_cup')
    expect(Ops::SqlScript.where('rel_path LIKE ?', 'results.done%')).to be_empty
    expect(Outbox::Reconciler).to be_imported
    expect(Ops::Event.last).to have_attributes(kind: 'outbox.imported')
  end

  it 'is idempotent' do
    described_class.perform_now(simulate: false, data_root:)
    expect(described_class.perform_now(simulate: false, data_root:).counts).to eq('unchanged' => 6)
  end
end
