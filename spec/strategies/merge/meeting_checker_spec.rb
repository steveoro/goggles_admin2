# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::MeetingChecker do
  # Use existing test DB meetings from the same season
  # Season 1: Circuito Regionale Emilia master CSI 2000/2001
  let(:source_meeting) { GogglesDb::Meeting.find(1) }  # 3A PROVA REGIONALE CSI
  let(:dest_meeting) { GogglesDb::Meeting.find(5) }    # 1A PROVA REGIONALE CSI

  describe '#initialize' do
    context 'with valid meetings in the same season' do
      subject { described_class.new(source: source_meeting, dest: dest_meeting) }

      it 'creates a checker instance' do
        expect(subject).to be_a(described_class)
      end

      it 'decorates the source meeting' do
        expect(subject.source).to respond_to(:display_label)
      end

      it 'decorates the destination meeting' do
        expect(subject.dest).to respond_to(:display_label)
      end

      it 'initializes empty data structures' do
        expect(subject.log).to eq([])
        expect(subject.errors).to eq([])
        expect(subject.warnings).to eq([])
        expect(subject.session_map).to eq({})
        expect(subject.event_map).to eq({})
        expect(subject.program_map).to eq({})
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

  describe '#run' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    context 'with meetings in the same season' do
      it 'returns true (merge feasible)' do
        expect(checker.run).to be true
      end

      it 'populates the log' do
        checker.run
        expect(checker.log).not_to be_empty
      end

      it 'has no errors' do
        checker.run
        expect(checker.errors).to be_empty
      end

      it 'builds the session_map' do
        checker.run
        expect(checker.session_map).not_to be_empty
      end

      it 'builds the event_map' do
        checker.run
        expect(checker.event_map).not_to be_empty
      end

      it 'builds the program_map' do
        checker.run
        expect(checker.program_map).not_to be_empty
      end
    end

    context 'with meetings in different seasons' do
      subject(:checker) { described_class.new(source: source_meeting, dest: different_season_meeting) }

      let(:different_season_meeting) do
        GogglesDb::Meeting.where.not(season_id: source_meeting.season_id)
                          .joins(:meeting_sessions)
                          .first
      end

      it 'returns false (merge not feasible)' do
        expect(checker.run).to be false
      end

      it 'adds an error about different seasons' do
        checker.run
        expect(checker.errors).to include(/different Seasons/)
      end
    end
  end

  describe 'session mapping accessors' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before(:each) { checker.run }

    describe '#shared_session_keys' do
      it 'returns an array' do
        expect(checker.shared_session_keys).to be_an(Array)
      end
    end

    describe '#src_only_session_keys' do
      it 'returns an array' do
        expect(checker.src_only_session_keys).to be_an(Array)
      end
    end

    describe '#dest_only_session_keys' do
      it 'returns an array' do
        expect(checker.dest_only_session_keys).to be_an(Array)
      end
    end

    it 'covers all sessions between shared, src-only, and dest-only' do
      total = checker.shared_session_keys.count +
              checker.src_only_session_keys.count +
              checker.dest_only_session_keys.count
      expect(total).to eq(checker.session_map.keys.count)
    end
  end

  describe 'event mapping accessors' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before(:each) { checker.run }

    describe '#shared_event_keys' do
      it 'returns an array' do
        expect(checker.shared_event_keys).to be_an(Array)
      end
    end

    describe '#src_only_event_keys' do
      it 'returns an array' do
        expect(checker.src_only_event_keys).to be_an(Array)
      end
    end

    describe '#dest_only_event_keys' do
      it 'returns an array' do
        expect(checker.dest_only_event_keys).to be_an(Array)
      end
    end

    it 'covers all events between shared, src-only, and dest-only' do
      total = checker.shared_event_keys.count +
              checker.src_only_event_keys.count +
              checker.dest_only_event_keys.count
      expect(total).to eq(checker.event_map.keys.count)
    end
  end

  describe 'program mapping accessors' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before(:each) { checker.run }

    describe '#shared_program_keys' do
      it 'returns an array' do
        expect(checker.shared_program_keys).to be_an(Array)
      end
    end

    describe '#src_only_program_keys' do
      it 'returns an array' do
        expect(checker.src_only_program_keys).to be_an(Array)
      end
    end

    describe '#dest_only_program_keys' do
      it 'returns an array' do
        expect(checker.dest_only_program_keys).to be_an(Array)
      end
    end

    it 'covers all programs between shared, src-only, and dest-only' do
      total = checker.shared_program_keys.count +
              checker.src_only_program_keys.count +
              checker.dest_only_program_keys.count
      expect(total).to eq(checker.program_map.keys.count)
    end
  end

  describe 'entity retrieval helpers' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    it 'returns source sessions' do
      expect(checker.src_sessions).to be_an(ActiveRecord::Relation)
      expect(checker.src_sessions.count).to eq(source_meeting.meeting_sessions.count)
    end

    it 'returns destination sessions' do
      expect(checker.dest_sessions).to be_an(ActiveRecord::Relation)
      expect(checker.dest_sessions.count).to eq(dest_meeting.meeting_sessions.count)
    end

    it 'returns source MIRs' do
      expect(checker.src_mirs).to be_an(ActiveRecord::Relation)
    end

    it 'returns destination MIRs' do
      expect(checker.dest_mirs).to be_an(ActiveRecord::Relation)
    end

    it 'returns source MRRs' do
      expect(checker.src_mrrs).to be_an(ActiveRecord::Relation)
    end

    it 'returns destination MRRs' do
      expect(checker.dest_mrrs).to be_an(ActiveRecord::Relation)
    end

    it 'returns source team scores' do
      expect(checker.src_team_scores).to be_an(ActiveRecord::Relation)
    end

    it 'returns destination team scores' do
      expect(checker.dest_team_scores).to be_an(ActiveRecord::Relation)
    end
  end

  describe '#display_report' do
    subject(:checker) { described_class.new(source: source_meeting, dest: dest_meeting) }

    before(:each) { checker.run }

    it 'outputs to stdout without raising' do
      expect { checker.display_report }.to output.to_stdout
    end
  end
end
