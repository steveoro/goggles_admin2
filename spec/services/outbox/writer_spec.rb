# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::Writer do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:sql) { "-- header\r\nSET AUTOCOMMIT = 0;\r\nSTART TRANSACTION;\r\nUPDATE x SET a='\xC3\xA8';\r\nCOMMIT;\r\n" }

  after(:each) { FileUtils.rm_rf(data_root) }

  def write(**options)
    described_class.write!(kind: 'calendar_link', name: 'calendar_link-12-150091', sql:, folder: '262',
                           origin: { producer: 'spec' }, data_root:, **options)
  end

  describe '.write!' do
    before(:each) { write_sql_file(data_root, 'results.sent/misc/0476-merge_teams-1-2.sql') }

    it 'writes results.new/<folder>/<seq>-<name>.sql verbatim, continuing the global sequence' do
      script = write
      expect(script).to be_a(Ops::SqlScript).and be_persisted
      expect(script.absolute_path).to eq(data_root.join('results.new/262/0477-calendar_link-12-150091.sql'))
      expect(File.binread(script.absolute_path)).to eq(sql.b)
    end

    it 'registers the row with kind, folder, season, sha256, size and origin' do
      script = write
      expect(script.reload).to have_attributes(
        seq: 477, rel_path: 'results.new/262/0477-calendar_link-12-150091.sql', filename: '0477-calendar_link-12-150091.sql',
        folder: '262', season_id: 262, kind: 'calendar_link', state: 'pending', applied_locally: true,
        sha256: Digest::SHA256.hexdigest(sql), byte_size: sql.bytesize, single_transaction: true,
        origin: { 'producer' => 'spec' }
      )
    end

    it 'leaves no temporary file behind' do
      write
      expect(Dir.children(data_root.join('results.new/262'))).to eq(['0477-calendar_link-12-150091.sql'])
    end

    it 'starts held when the script was not applied locally' do
      script = write(applied_locally: false)
      expect(script).to have_attributes(state: 'held', held_reason: 'not_applied_locally', applied_locally: false)
    end

    it 'starts held on request' do
      expect(write(held: true)).to have_attributes(state: 'held', held_reason: 'operator')
    end

    it 'keeps an explicit prefix for the file name only' do
      script = write(prefix: 12)
      expect(script).to have_attributes(seq: 477, filename: '0012-calendar_link-12-150091.sql')
    end

    it 'refuses unknown kinds, blank names and folders with a path' do
      expect { write(kind: 'nope') }.to raise_error(ArgumentError)
      expect { described_class.write!(kind: 'merge', name: ' ', sql:, folder: 'misc', data_root:) }.to raise_error(ArgumentError)
      expect { described_class.write!(kind: 'merge', name: 'x', sql:, folder: '../etc', data_root:) }.to raise_error(ArgumentError)
    end

    it 'writes the file all the same when the ops DB is not available' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      script = nil
      expect { script = write }.not_to change(Ops::SqlScript, :count)
      expect(script).to be_a(described_class::UnregisteredScript)
      expect(script).not_to be_persisted
      expect(File.binread(script.absolute_path)).to eq(sql.b)
    end

    it 'leaves neither file nor row when the producer transaction rolls back (discard! in the rescue)' do
      script = nil
      expect do
        ActiveRecord::Base.transaction do
          script = write
          raise ActiveRecord::Rollback
        end
        described_class.discard!(script)
      end.not_to change(Ops::SqlScript, :count)
      expect(script.absolute_path).not_to exist
    end
  end

  describe '.mark_applied_locally!' do
    it 're-sequences a held script when other scripts were written meanwhile' do
      held = write(applied_locally: false)
      first = held.seq
      described_class.write!(kind: 'merge', name: 'merge_teams-3-4', sql:, folder: 'misc', data_root:)
      described_class.mark_applied_locally!(held.absolute_path, data_root:)

      held.reload
      new_name = format('%04d-calendar_link-12-150091.sql', first + 2)
      expect(held).to have_attributes(state: 'pending', applied_locally: true, held_reason: nil, seq: first + 2, filename: new_name)
      expect(data_root.join('results.new/262', new_name)).to exist
      expect(data_root.join('results.new/262', format('%04d-calendar_link-12-150091.sql', first))).not_to exist
      expect(Ops::Event.last).to have_attributes(kind: 'outbox.resequenced')
    end

    it 'keeps the number of a held script that is still the last one' do
      held = write(applied_locally: false)
      first = held.seq
      described_class.mark_applied_locally!(held, data_root:)
      expect(held.reload).to have_attributes(state: 'pending', seq: first)
    end

    it 'keeps an operator hold' do
      held = write(held: true)
      described_class.mark_applied_locally!(held, data_root:)
      expect(held.reload).to have_attributes(state: 'held', applied_locally: true)
    end

    it 'returns nil for an unregistered path' do
      expect(described_class.mark_applied_locally!(data_root.join('results.new/262/0009-x.sql'), data_root:)).to be_nil
    end
  end

  it '.mark_apply_failed! holds the script with the error' do
    script = write(applied_locally: false)
    described_class.mark_apply_failed!(script, error: 'ERROR 1064', data_root:)
    expect(script.reload).to have_attributes(state: 'held', held_reason: 'local_apply_failed', last_error: 'ERROR 1064')
  end
end
