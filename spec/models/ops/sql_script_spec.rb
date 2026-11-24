# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::SqlScript do
  include ActiveSupport::Testing::TimeHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  def script(rel_path, **attributes)
    create_sql_script(data_root, rel_path, **attributes)
  end

  describe 'validations' do
    it 'requires the core attributes and known state, kind and held reason' do
      row = script('results.new/262/0010-a-lt4.sql')
      expect(row).to be_valid
      %i[seq rel_path filename folder kind sha256 state].each do |attr|
        expect(row.dup.tap { |copy| copy[attr] = nil }).not_to be_valid
      end
      expect(row.dup.tap { |copy| copy.state = 'applied' }).not_to be_valid
      expect(row.dup.tap { |copy| copy.kind = 'whatever' }).not_to be_valid
      expect(row.dup.tap { |copy| copy.held_reason = 'because' }).not_to be_valid
    end

    it 'keeps seq and rel_path unique' do
      row = script('results.new/262/0010-a-lt4.sql')
      expect(row.dup.tap { |copy| copy.seq = 99 }).not_to be_valid
      expect(row.dup.tap { |copy| copy.rel_path = 'results.new/262/other.sql' }).not_to be_valid
    end

    it 'truncates last_error to 4 KB' do
      row = script('results.new/262/0010-a-lt4.sql')
      row.update!(last_error: 'x' * 10_000)
      expect(row.reload.last_error.size).to eq(4.kilobytes)
    end
  end

  describe 'scopes' do
    it 'splits the rows into needs push, on the server and history, by seq' do
      held = script('results.new/misc/0012-b.sql', state: 'held', held_reason: 'operator')
      pending = script('results.new/262/0011-a-lt4.sql')
      sent = script('results.sent/262/0005-c-lt4.sql', state: 'sent')
      legacy = script('results.sent/262/0001-d-lt4.sql')
      expect(described_class.needs_push).to eq([pending, held])
      expect(described_class.on_server).to eq([sent])
      expect(described_class.history).to eq([legacy])
    end
  end

  describe '.kinds_for' do
    it 'returns the kinds of the registered paths in one query' do
      script('results.new/262/0011-a-lt4.sql')
      script('results.new/262/0012-team_manager-1-2.sql')
      expect(described_class.kinds_for(%w[results.new/262/0011-a-lt4.sql results.new/262/0012-team_manager-1-2.sql
                                          results.new/262/0013-unknown.sql]))
        .to eq('results.new/262/0011-a-lt4.sql' => 'commit', 'results.new/262/0012-team_manager-1-2.sql' => 'team_manager')
      expect(described_class.kind_for('results.new/262/0013-unknown.sql')).to be_nil
    end
  end

  describe '#blockers' do
    it 'lists the lower-seq pending, pushing and in-doubt scripts, never the held ones' do
      first = script('results.new/262/0010-a-lt4.sql')
      script('results.new/262/0011-b-lt4.sql', state: 'held', held_reason: 'operator')
      doubt = script('results.new/262/0012-c-lt4.sql', state: 'in_doubt')
      last = script('results.new/262/0013-d-lt4.sql')
      expect(last.blockers).to eq([first, doubt])
      expect(first).not_to be_blocked
    end
  end

  describe 'transitions' do
    let(:row) { script('results.new/262/0010-a-lt4.sql') }

    it 'holds and releases a script applied locally' do
      row.hold!
      expect(row.reload).to have_attributes(state: 'held', held_reason: 'operator')
      row.release!
      expect(row.reload).to have_attributes(state: 'pending', held_reason: nil)
    end

    it 'refuses to release a script not applied locally unless forced' do
      row.update!(state: 'held', held_reason: 'not_applied_locally', applied_locally: false)
      expect { row.release! }.to raise_error(described_class::InvalidTransition)
      row.release!(force: true)
      expect(row.reload).to be_pending
    end

    it 'goes pending -> pushing -> sent' do
      row.mark_pushing!
      expect(row.reload).to have_attributes(state: 'pushing', push_attempts: 1)
      row.mark_sent!(rel_path: 'results.sent/262/0010-a-lt4.sql', remote_iq_id: 77, target_api_url: 'http://x', target_env: 'unknown')
      expect(row.reload).to have_attributes(state: 'sent', remote_iq_id: 77, rel_path: 'results.sent/262/0010-a-lt4.sql')
      expect(row.pushed_at).to be_present
    end

    it 'goes back to pending with the error when a POST is rejected' do
      row.mark_pushing!
      row.mark_rejected!('Validation failure')
      expect(row.reload).to have_attributes(state: 'pending', last_error: 'Validation failure')
    end

    it 'raises on an invalid move' do
      expect { row.mark_sent!(rel_path: 'x', remote_iq_id: 1, target_api_url: 'u', target_env: 'e') }
        .to raise_error(described_class::InvalidTransition)
      expect { row.mark_executed_unreported! }.to raise_error(described_class::InvalidTransition)
    end

    it 'requires a note to discard' do
      expect { row.mark_discarded!(note: ' ') }.to raise_error(described_class::InvalidTransition)
      row.mark_discarded!(note: 'duplicate', rel_path: 'results.new/discarded/262/0010-a-lt4.sql')
      expect(row.reload).to have_attributes(state: 'discarded', note: 'duplicate')
    end

    it 'remembers the state before missing and restores it' do
      row.hold!
      row.mark_missing!
      expect(row.reload).to have_attributes(state: 'missing', previous_state: 'held')
      row.mark_reappeared!
      expect(row.reload).to have_attributes(state: 'held', previous_state: nil)
    end

    it 'detects a stale pushing row' do
      row.mark_pushing!
      expect(row).not_to be_stale_pushing
      travel_to(11.minutes.from_now) { expect(row).to be_stale_pushing }
    end
  end

  it 'resolves its absolute path under its data root' do
    row = script('results.new/262/0010-a-lt4.sql')
    expect(row.absolute_path).to eq(data_root.join('results.new/262/0010-a-lt4.sql'))
    expect(row).to be_file_exists
    expect(row).to be_in_new_dir
  end
end
