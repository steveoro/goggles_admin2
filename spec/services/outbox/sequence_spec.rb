# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::Sequence do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  context 'with scripts in several folders' do
    before(:each) do
      write_sql_file(data_root, 'results.new/262/0420-a-lt4.sql')
      write_sql_file(data_root, 'results.sent/misc/0476-merge_teams-1-2.sql')
      write_sql_file(data_root, 'redo/0478-merge_badges-3-4.sql')
      write_sql_file(data_root, 'results.new/old-subseeded/017-232-standard_timings.sql')
      write_sql_file(data_root, 'results.done/262/0999-archived-lt4.sql') # never counted
      write_sql_file(data_root, 'results.new/262/notes.sql') # no prefix
    end

    it 'returns the global max over results.new, results.sent and redo (3- and 4-digit prefixes)' do
      expect(described_class.disk_max(data_root)).to eq(478)
      expect(described_class.current_max(data_root:)).to eq(478)
    end

    it 'allocates the next number and stores it as the floor' do
      expect(described_class.next!(data_root:)).to eq(479)
      expect(Ops::Setting.fetch('outbox.last_seq')).to eq(479)
      expect(described_class.next!(data_root:)).to eq(480)
      expect(described_class.current_max(data_root:)).to eq(480)
    end

    it 'never goes below the registry max' do
      create_sql_script(data_root, 'results.new/262/0420-a-lt4.sql', seq: 600, file: false)
      expect(described_class.next!(data_root:)).to eq(601)
    end

    it 'falls back to the disk max when the ops DB is not available' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect(described_class.next!(data_root:)).to eq(479)
      expect(described_class.current_max(data_root:)).to eq(478)
    end
  end

  it 'starts at 1 on an empty data root' do
    expect(described_class.disk_max(data_root)).to eq(0)
    expect(described_class.next!(data_root:)).to eq([Ops::Setting.fetch('outbox.last_seq', 0).to_i, 1].max)
  end

  describe 'concurrent allocation' do
    self.use_transactional_tests = false

    let(:tmp_dir) { Dir.mktmpdir }

    before(:each) do
      use_temp_ops_db(tmp_dir)
      Ops::Database.prepare!
    end

    after(:each) do
      Ops::ApplicationRecord.connection_handler.clear_all_connections!
      Ops::Database.reset_state!
      FileUtils.rm_rf(tmp_dir)
    end

    it 'gives distinct numbers to two threads' do
      # (Ops::ApplicationRecord connects through the stubbed config: re-point its pool at the temp DB)
      Ops::ApplicationRecord.establish_connection(Ops::Database.db_config)
      numbers = Array.new(2) do
        Thread.new { Array.new(10) { described_class.next!(data_root:) } }
      end.flat_map(&:value)
      expect(numbers.uniq.size).to eq(20)
      expect(numbers.max).to eq(20)
    ensure
      Ops::ApplicationRecord.establish_connection(:ops)
    end
  end
end
