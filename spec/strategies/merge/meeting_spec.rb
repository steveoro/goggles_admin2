# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::Meeting do
  # Use existing test DB meetings from the same season
  let(:source_meeting) { GogglesDb::Meeting.find(1) }  # Season 1
  let(:dest_meeting) { GogglesDb::Meeting.find(5) }    # Season 1

  describe 'class methods' do
    describe '.start_transaction_log' do
      it 'returns an array with transaction start SQL' do
        result = described_class.start_transaction_log
        expect(result).to be_an(Array)
        expect(result.join).to include('START TRANSACTION')
      end
    end

    describe '.end_transaction_log' do
      it 'returns an array with COMMIT SQL' do
        result = described_class.end_transaction_log
        expect(result).to be_an(Array)
        expect(result.join).to include('COMMIT')
      end
    end
  end

  describe '#initialize' do
    context 'with valid meetings in the same season' do
      subject { described_class.new(source: source_meeting, dest: dest_meeting) }

      it 'creates a merger instance' do
        expect(subject).to be_a(described_class)
      end

      it 'creates an internal MeetingChecker' do
        expect(subject.checker).to be_a(Merge::MeetingChecker)
      end

      it 'decorates the source meeting' do
        expect(subject.source).to respond_to(:display_label)
      end

      it 'decorates the destination meeting' do
        expect(subject.dest).to respond_to(:display_label)
      end

      it 'initializes empty sql_log' do
        expect(subject.sql_log).to eq([])
      end

      it 'initializes empty warning_log' do
        expect(subject.warning_log).to eq([])
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when source is not a Meeting' do
        expect { described_class.new(source: 'not a meeting', dest: dest_meeting) }
          .to raise_error(ArgumentError, /must be Meetings/)
      end

      it 'raises ArgumentError when dest is not a Meeting' do
        expect { described_class.new(source: source_meeting, dest: 'not a meeting') }
          .to raise_error(ArgumentError, /must be Meetings/)
      end

      it 'raises ArgumentError when source and dest are identical' do
        expect { described_class.new(source: source_meeting, dest: source_meeting) }
          .to raise_error(ArgumentError, /Identical source and destination/)
      end
    end
  end

  describe '#prepare' do
    subject(:merger) { described_class.new(source: source_meeting, dest: dest_meeting) }

    context 'with meetings in the same season' do
      it 'returns true' do
        expect(merger.prepare).to be true
      end

      it 'populates the sql_log' do
        merger.prepare
        expect(merger.sql_log).not_to be_empty
      end

      it 'includes transaction statements' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('START TRANSACTION')
        expect(sql).to include('COMMIT')
      end

      it 'includes session handling SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== SESSIONS ===')
      end

      it 'includes event handling SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== EVENTS ===')
      end

      it 'includes program handling SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== PROGRAMS ===')
      end

      it 'includes MIR handling SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== INDIVIDUAL RESULTS')
      end

      it 'includes relay handling SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== RELAY RESULTS')
      end

      it 'includes team scores SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== TEAM SCORES ===')
      end

      it 'includes deprecated entities SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== DEPRECATED ENTITIES')
      end

      it 'includes calendar SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('=== CALENDAR ===')
      end

      it 'includes source deletion SQL' do
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).to include('DELETE FROM meetings WHERE id=')
      end

      it 'does not allow a second run' do
        merger.prepare
        expect(merger.prepare).to be false
      end
    end

    context 'with meetings in different seasons' do
      let(:different_season_meeting) do
        GogglesDb::Meeting.where.not(season_id: source_meeting.season_id)
                          .joins(:meeting_sessions)
                          .first
      end

      subject(:merger) { described_class.new(source: source_meeting, dest: different_season_meeting) }

      it 'returns false' do
        expect(merger.prepare).to be false
      end

      it 'does not populate sql_log' do
        merger.prepare
        expect(merger.sql_log).to be_empty
      end
    end
  end

  describe '#single_transaction_sql_log' do
    subject(:merger) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before { merger.prepare }

    it 'returns the sql_log wrapped in transaction' do
      result = merger.single_transaction_sql_log
      expect(result).to be_an(Array)
      expect(result.join).to include('TRANSACTION')
      expect(result.last).to include('COMMIT')
    end
  end

  describe 'delegated methods' do
    subject(:merger) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before { merger.prepare }

    it 'delegates log to checker' do
      expect(merger.log).to eq(merger.checker.log)
    end

    it 'delegates errors to checker' do
      expect(merger.errors).to eq(merger.checker.errors)
    end

    it 'delegates warnings to checker' do
      expect(merger.warnings).to eq(merger.checker.warnings)
    end
  end

  describe '#display_report' do
    subject(:merger) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before { merger.prepare }

    it 'outputs to stdout without raising' do
      expect { merger.display_report }.to output.to_stdout
    end
  end
end
