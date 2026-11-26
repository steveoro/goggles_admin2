# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Progress do
  describe Import::Progress::Cable do
    let(:broadcasts) { [] }

    before(:each) do
      allow(ActionCable.server).to receive(:broadcast) { |channel, payload| broadcasts << [channel, payload] }
    end

    it 'broadcasts each tick on ImportStatusChannel with its op, an increasing seq and the scope' do
      sink = described_class.new(scope: 'sample-200RA-l4')
      sink.call('Map teams', 1, 2)
      sink.call('Map teams', 2, 2)

      expect(broadcasts.map(&:first)).to all(eq('ImportStatusChannel'))
      expect(broadcasts.map(&:last)).to eq(
        [{ op: sink.op, seq: 1, scope: 'sample-200RA-l4', msg: 'Map teams', progress: 1, total: 2 },
         { op: sink.op, seq: 2, scope: 'sample-200RA-l4', msg: 'Map teams', progress: 2, total: 2 }]
      )
      expect(sink).to be_open
    end

    it 'gives each sink its own op id, and a nil scope by default' do
      first = described_class.new
      second = described_class.new(scope: '')
      expect(first.op).to be_present
      expect(second.op).not_to eq(first.op)
      first.call('x', 1, 1)
      expect(broadcasts.last.last).to include(scope: nil)
    end

    it "sends one 'done' after a tick, and nothing more on a second call" do
      sink = described_class.new(scope: 'a')
      sink.call('x', 1, 1)
      op = sink.op
      sink.done
      sink.done
      expect(broadcasts.map(&:last).last).to eq({ op:, state: 'done' })
      expect(broadcasts.count { |_channel, payload| payload[:state] == 'done' }).to eq(1)
      expect(sink).not_to be_open
    end

    it "sends no 'done' when no tick was sent (a request that built nothing broadcasts nothing)" do
      sink = described_class.new(scope: 'a')
      sink.done
      expect(broadcasts).to be_empty
      expect(sink).not_to be_open
    end

    it "closes the operation on 'done': a later tick starts a new op, with seq from 1 again" do
      sink = described_class.new(scope: 'a')
      sink.call('x', 1, 2)
      sink.call('x', 2, 2)
      sink.done
      sink.call('y', 1, 1)
      sink.done
      payloads = broadcasts.map(&:last)
      expect(payloads.map { |payload| payload[:seq] || payload[:state] }).to eq([1, 2, 'done', 1, 'done'])
      first_op, second_op = payloads.pluck(:op).uniq
      expect(second_op).not_to eq(first_op)
      expect(payloads.first(3).pluck(:op)).to all(eq(first_op))
      expect(payloads.last(2).pluck(:op)).to all(eq(second_op))
      expect(payloads[3]).to include(scope: 'a')
    end

    it 'never raises' do
      allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError, 'cable down')
      sink = described_class.new
      expect { sink.call('x', 1, 1) }.not_to raise_error
      expect { sink.done }.not_to raise_error
    end
  end

  describe '.default' do
    it 'is a Null sink: a caller passing no sink broadcasts nothing' do
      expect(described_class.default).to be_an(Import::Progress::Null)
    end

    it 'is the default of the pipeline, the solvers, the populator and the committer' do
      expect(DataFix::Pipeline.new('/tmp/none-lt4.json').progress).to be_an(Import::Progress::Null)
      [Import::Solvers::TeamSolver, Import::Solvers::SwimmerSolver, Import::Solvers::ResultSolver].each do |solver|
        expect(solver.new(season: GogglesDb::Season.last).instance_variable_get(:@progress)).to be_an(Import::Progress::Null)
      end
      populator = Import::Phase5Populator.new(source_path: 'x', phase1_path: 'x', phase2_path: 'x', phase3_path: 'x', phase4_path: 'x')
      expect(populator.instance_variable_get(:@progress)).to be_an(Import::Progress::Null)
      committer = Import::Committers::Main.new(phase1_path: 'x', phase2_path: 'x', phase3_path: 'x', phase4_path: 'x', phase5_path: 'x',
                                               source_path: 'x')
      expect(committer.instance_variable_get(:@progress)).to be_an(Import::Progress::Null)
    end
  end

  describe Import::Progress::Null do
    it 'discards everything without broadcasting, done included' do
      allow(ActionCable.server).to receive(:broadcast)
      sink = described_class.new
      expect(sink.call('x', 1, 2)).to be_nil
      expect(sink.done).to be_nil
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

    it 'answers done without writing nor broadcasting' do
      allow(ActionCable.server).to receive(:broadcast)
      expect(sink.done).to be_nil
      expect(record).not_to have_received(:record_progress!)
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'never raises when the write fails' do
      allow(record).to receive(:record_progress!).and_raise(ActiveRecord::StatementTimeout, 'database is locked')
      expect { sink.call('a', 1, 1) }.not_to raise_error
    end
  end
end
