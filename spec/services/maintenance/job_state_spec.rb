# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::JobState do
  it 'is unknown with the test adapter or without a job id' do
    expect(described_class.for('abc')).to eq(:unknown)
    allow(Dashboard::QueueActivity).to receive(:solid_queue?).and_return(true)
    expect(described_class.for(nil)).to eq(:unknown)
  end

  context 'with Solid Queue' do
    before(:each) { allow(Dashboard::QueueActivity).to receive(:solid_queue?).and_return(true) }

    # (plain doubles: the test env has no Solid Queue tables to verify a SolidQueue::Job against)
    def job(finished_at: nil, failed_execution: nil)
      double('SolidQueue::Job', finished_at:, failed_execution:) # rubocop:disable RSpec/VerifiedDoubles
    end

    it 'is dead when the job is missing, finished or failed, active otherwise' do
      allow(described_class).to receive(:find_job).with('gone').and_return(nil)
      allow(described_class).to receive(:find_job).with('done').and_return(job(finished_at: Time.current))
      allow(described_class).to receive(:find_job).with('failed').and_return(job(failed_execution: :row))
      allow(described_class).to receive(:find_job).with('live').and_return(job)
      expect(%w[gone done failed live].map { |id| described_class.for(id) }).to eq(%i[dead dead dead active])
    end

    it 'is unknown when the queue DB cannot be read' do
      allow(described_class).to receive(:find_job).and_raise(ActiveRecord::StatementInvalid, 'no such table')
      expect(described_class.for('x')).to eq(:unknown)
    end
  end
end
