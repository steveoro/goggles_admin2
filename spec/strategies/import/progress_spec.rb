# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Progress do
  describe Import::Progress::Cable do
    it 'broadcasts on ImportStatusChannel and never raises' do
      allow(ActionCable.server).to receive(:broadcast)
      described_class.new.call('Map teams', 1, 2)
      expect(ActionCable.server).to have_received(:broadcast).with('ImportStatusChannel', { msg: 'Map teams', progress: 1, total: 2 })

      allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError, 'cable down')
      expect { described_class.new.call('x', 1, 1) }.not_to raise_error
    end
  end

  describe Import::Progress::Null do
    it 'discards everything without broadcasting' do
      allow(ActionCable.server).to receive(:broadcast)
      expect(described_class.new.call('x', 1, 2)).to be_nil
      expect(ActionCable.server).not_to have_received(:broadcast)
    end
  end

  describe Import::Progress::Ops do
    let(:record) { instance_double(Ops::CommitReport, record_progress!: true) }
    let(:now) { [0.0] }
    let(:sink) { described_class.new(record, interval: 1.0, clock: -> { now.first }) }

    it 'writes at most once per interval, plus the last step, and never broadcasts' do
      allow(ActionCable.server).to receive(:broadcast)
      sink.call('a', 1, 10)
      sink.call('b', 2, 10) # (throttled)
      now[0] = 1.5
      sink.call('c', 3, 10)
      sink.call('d', 10, 10) # (last step: always written)

      expect(record).to have_received(:record_progress!).exactly(3).times
      expect(record).to have_received(:record_progress!).with(message: 'd', current: 10, total: 10)
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'never raises when the write fails' do
      allow(record).to receive(:record_progress!).and_raise(ActiveRecord::StatementTimeout, 'database is locked')
      expect { sink.call('a', 1, 1) }.not_to raise_error
    end
  end
end
