# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Purge::Meeting, type: :strategy do
  # Find a meeting with MIRs for testing
  let(:meeting_with_data) do
    meeting_id = GogglesDb::MeetingIndividualResult
                 .joins(meeting_program: { meeting_event: :meeting_session })
                 .select('meeting_sessions.meeting_id')
                 .group('meeting_sessions.meeting_id')
                 .having('COUNT(meeting_individual_results.id) > 5')
                 .limit(1)
                 .pick('meeting_sessions.meeting_id')
    GogglesDb::Meeting.find(meeting_id)
  end

  let(:meeting) { meeting_with_data }

  describe '#initialize' do
    context 'with valid meeting argument' do
      subject(:purger) { described_class.new(meeting: meeting) }

      it 'creates an instance' do
        expect(purger).to be_a(described_class)
      end

      it 'stores the meeting' do
        expect(purger.meeting).to eq(meeting)
      end

      it 'defaults stop_at_events to false' do
        expect(purger.stop_at_events).to be false
      end

      it 'initializes empty sql_log' do
        expect(purger.sql_log).to eq([])
      end

      it 'initializes empty row_counts' do
        expect(purger.row_counts).to eq({})
      end
    end

    context 'with stop_at_events: true' do
      subject(:purger) { described_class.new(meeting: meeting, stop_at_events: true) }

      it 'stores stop_at_events as true' do
        expect(purger.stop_at_events).to be true
      end
    end

    context 'with a non-Meeting argument' do
      it 'raises an ArgumentError' do
        expect { described_class.new(meeting: 'not-a-meeting') }.to raise_error(ArgumentError)
      end
    end
  end

  describe '#prepare' do
    subject(:purger) { described_class.new(meeting: meeting) }

    before(:each) { purger.prepare }

    it 'populates sql_log with SQL strings' do
      expect(purger.sql_log).to be_an(Array)
      expect(purger.sql_log).not_to be_empty
    end

    it 'includes DELETE statements' do
      expect(purger.sql_log.join).to include('DELETE')
    end

    it 'populates row_counts hash' do
      expect(purger.row_counts).to be_a(Hash)
      expect(purger.row_counts).not_to be_empty
    end

    it 'includes row counts for laps' do
      expect(purger.row_counts).to have_key('laps')
    end

    it 'includes row counts for meeting_individual_results' do
      expect(purger.row_counts).to have_key('meeting_individual_results')
    end

    it 'includes row counts for meeting_programs' do
      expect(purger.row_counts).to have_key('meeting_programs')
    end
  end

  describe '#prepare with full purge (default)' do
    subject(:purger) { described_class.new(meeting: meeting) }

    before(:each) { purger.prepare }

    it 'includes DELETE for laps' do
      expect(purger.sql_log.join).to include('DELETE l')
      expect(purger.sql_log.join).to include('FROM laps')
    end

    it 'includes DELETE for relay_laps' do
      expect(purger.sql_log.join).to include('DELETE rl')
      expect(purger.sql_log.join).to include('FROM relay_laps')
    end

    it 'includes DELETE for individual_records' do
      expect(purger.sql_log.join).to include('DELETE ir')
      expect(purger.sql_log.join).to include('FROM individual_records')
    end

    it 'includes DELETE for meeting_relay_swimmers' do
      expect(purger.sql_log.join).to include('DELETE mrs')
      expect(purger.sql_log.join).to include('FROM meeting_relay_swimmers')
    end

    it 'includes DELETE for meeting_individual_results' do
      expect(purger.sql_log.join).to include('DELETE mir')
      expect(purger.sql_log.join).to include('FROM meeting_individual_results')
    end

    it 'includes DELETE for meeting_relay_results' do
      expect(purger.sql_log.join).to include('DELETE mrr')
      expect(purger.sql_log.join).to include('FROM meeting_relay_results')
    end

    it 'includes DELETE for meeting_entries' do
      expect(purger.sql_log.join).to include('DELETE me')
      expect(purger.sql_log.join).to include('FROM meeting_entries')
    end

    it 'includes DELETE for meeting_programs' do
      expect(purger.sql_log.join).to include('DELETE mp')
      expect(purger.sql_log.join).to include('FROM meeting_programs')
    end

    it 'includes DELETE for meeting_event_reservations' do
      expect(purger.sql_log.join).to include('DELETE FROM meeting_event_reservations')
    end

    it 'includes DELETE for meeting_relay_reservations' do
      expect(purger.sql_log.join).to include('DELETE FROM meeting_relay_reservations')
    end

    it 'includes DELETE for meeting_events' do
      expect(purger.sql_log.join).to include('DELETE me')
      expect(purger.sql_log.join).to include('FROM meeting_events')
    end

    it 'includes DELETE for meeting_sessions' do
      expect(purger.sql_log.join).to include('DELETE FROM meeting_sessions')
    end

    it 'includes DELETE for meeting_reservations' do
      expect(purger.sql_log.join).to include('DELETE FROM meeting_reservations')
    end

    it 'includes DELETE for meeting_team_scores' do
      expect(purger.sql_log.join).to include('DELETE FROM meeting_team_scores')
    end

    it 'includes DELETE for calendars' do
      expect(purger.sql_log.join).to include('DELETE FROM calendars')
    end

    it 'includes DELETE for the meeting row itself (last)' do
      expect(purger.sql_log.join).to include('DELETE FROM meetings WHERE id =')
    end
  end

  describe '#prepare with stop_at_events: true' do
    subject(:purger) { described_class.new(meeting: meeting, stop_at_events: true) }

    before(:each) { purger.prepare }

    it 'includes DELETE for laps' do
      expect(purger.sql_log.join).to include('FROM laps')
    end

    it 'includes DELETE for meeting_programs' do
      expect(purger.sql_log.join).to include('DELETE mp')
      expect(purger.sql_log.join).to include('FROM meeting_programs')
    end

    it 'does NOT include DELETE for meeting_events' do
      expect(purger.sql_log.join).not_to include('FROM meeting_events')
    end

    it 'does NOT include DELETE for meeting_sessions' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meeting_sessions')
    end

    it 'does NOT include DELETE for meeting_reservations' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meeting_reservations')
    end

    it 'does NOT include DELETE for meeting_team_scores' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meeting_team_scores')
    end

    it 'does NOT include DELETE for meeting_event_reservations' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meeting_event_reservations')
    end

    it 'does NOT include DELETE for meeting_relay_reservations' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meeting_relay_reservations')
    end

    it 'does NOT include DELETE for calendars' do
      expect(purger.sql_log.join).not_to include('DELETE FROM calendars')
    end

    it 'does NOT include DELETE for the meeting row itself' do
      expect(purger.sql_log.join).not_to include('DELETE FROM meetings WHERE')
    end

    it 'does not include row counts for tables beyond meeting_programs' do
      expect(purger.row_counts).not_to have_key('meeting_events')
      expect(purger.row_counts).not_to have_key('meeting_sessions')
      expect(purger.row_counts).not_to have_key('meetings')
    end
  end

  describe 'deletion order' do
    subject(:purger) { described_class.new(meeting: meeting) }

    before(:each) { purger.prepare }

    it 'deletes laps before meeting_individual_results' do
      sql = purger.sql_log.join
      expect(sql.index('FROM laps')).to be < sql.index('FROM meeting_individual_results')
    end

    it 'deletes relay_laps before meeting_relay_swimmers' do
      sql = purger.sql_log.join
      expect(sql.index('FROM relay_laps')).to be < sql.index('FROM meeting_relay_swimmers')
    end

    it 'deletes meeting_relay_swimmers before meeting_relay_results' do
      sql = purger.sql_log.join
      expect(sql.index('FROM meeting_relay_swimmers')).to be < sql.index('FROM meeting_relay_results')
    end

    it 'deletes meeting_individual_results before meeting_programs' do
      sql = purger.sql_log.join
      expect(sql.index('FROM meeting_individual_results')).to be < sql.index('FROM meeting_programs')
    end

    it 'deletes meeting_programs before meeting_events' do
      sql = purger.sql_log.join
      expect(sql.index('FROM meeting_programs')).to be < sql.index('FROM meeting_events')
    end

    it 'deletes meeting_events before meeting_sessions' do
      sql = purger.sql_log.join
      expect(sql.index('FROM meeting_events')).to be < sql.index('DELETE FROM meeting_sessions')
    end

    it 'deletes the meeting row last' do
      sql = purger.sql_log.join
      expect(sql.index('DELETE FROM meetings WHERE')).to be > sql.index('DELETE FROM meeting_sessions')
    end
  end

  describe '#single_transaction_sql_log' do
    subject(:purger) { described_class.new(meeting: meeting) }

    before(:each) { purger.prepare }

    let(:wrapped) { purger.single_transaction_sql_log }

    it 'returns an array' do
      expect(wrapped).to be_an(Array)
    end

    it 'starts with SET AUTOCOMMIT' do
      expect(wrapped.join).to include('SET AUTOCOMMIT = 0;')
    end

    it 'includes START TRANSACTION' do
      expect(wrapped.join).to include('START TRANSACTION;')
    end

    it 'ends with COMMIT' do
      expect(wrapped.last).to eq('COMMIT;')
    end

    it 'wraps the sql_log content' do
      expect(wrapped.join).to include('DELETE')
    end
  end

  describe '#single_transaction_sql_log when sql_log is empty' do
    subject(:purger) { described_class.new(meeting: meeting) }

    it 'returns empty array' do
      expect(purger.single_transaction_sql_log).to eq([])
    end
  end
end
