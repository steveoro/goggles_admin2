# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::OperationRun do
  it 'validates mode, status and origin' do
    expect(FactoryBot.build(:ops_operation_run)).to be_valid
    expect(FactoryBot.build(:ops_operation_run, mode: 'other')).not_to be_valid
    expect(FactoryBot.build(:ops_operation_run, status: 'other')).not_to be_valid
    expect(FactoryBot.build(:ops_operation_run, origin: 'other')).not_to be_valid
  end

  it 'is claimed once (queued -> running)' do
    run = FactoryBot.create(:ops_operation_run)
    expect(run.claim!(job_id: 'j1')).to be(true)
    expect(run).to have_attributes(status: 'running', job_id: 'j1', started_at: be_present)
    expect(described_class.find(run.id).claim!).to be(false)
  end

  it 'caps long texts on a valid UTF-8 boundary' do
    text = 'é' * 100
    capped = described_class.cap(text, 51)
    expect(capped.bytesize).to be <= 51
    expect(capped).to be_valid_encoding
    expect(capped).to end_with(described_class::TRUNCATED_MARK)
    expect(described_class.cap('short', 51)).to eq('short')
  end

  it 'is appliable only as a succeeded dry run with SQL, no error and something to do' do
    run = FactoryBot.create(:ops_operation_run, :previewed)
    expect(run).to be_appliable
    expect(FactoryBot.build(:ops_operation_run, :previewed, error_messages: ['x'])).not_to be_appliable
    expect(FactoryBot.build(:ops_operation_run, :previewed, summary: { 'empty' => true })).not_to be_appliable
    expect(FactoryBot.build(:ops_operation_run, :previewed, mode: 'apply')).not_to be_appliable

    apply = FactoryBot.create(:ops_operation_run, mode: 'apply', parent_run: run)
    expect(run.applied_or_applying?).to be(true)
    expect(run.latest_apply).to eq(apply)
    apply.finish!(status: 'failed')
    expect(run.applied_or_applying?).to be(false)
  end

  it 'refuses with a translated reason' do
    run = FactoryBot.create(:ops_operation_run)
    run.refuse!(:digest_changed)
    expect(run.reload).to have_attributes(status: 'refused', refusal_reason: 'digest_changed', finished_at: be_present)
    expect(run.error_list).to eq([I18n.t('maintenance.refusals.digest_changed')])
  end

  describe '#interrupted?' do
    include ActiveSupport::Testing::TimeHelpers

    let(:run) { FactoryBot.create(:ops_operation_run, mode: 'apply', status: 'running', started_at: 10.minutes.ago, job_id: 'job-1') }

    it 'is true as soon as the Solid Queue job is gone, finished or failed (worker killed)' do
      allow(Maintenance::JobState).to receive(:for).with('job-1').and_return(:dead)
      expect(run).to be_interrupted
      expect(run.display_status).to eq('interrupted')
    end

    it 'trusts a live job up to its concurrency duration' do
      allow(Maintenance::JobState).to receive(:for).and_return(:active)
      expect(run).not_to be_interrupted
      expect(run.interrupted?(now: Time.current + Maintenance::RunJob.concurrency_duration)).to be(true)
    end

    it 'without job information, counts a run pending longer than STALE_AFTER as interrupted' do
      expect(Maintenance::JobState.for('job-1')).to eq(:unknown) # (test adapter)
      expect(run).not_to be_interrupted
      travel(described_class::STALE_AFTER) { expect(run.reload).to be_interrupted }
      queued = FactoryBot.create(:ops_operation_run, mode: 'apply', created_at: 31.minutes.ago)
      expect(queued).to be_interrupted
    end

    it 'is never true for a finished run' do
      allow(Maintenance::JobState).to receive(:for).and_return(:dead)
      run.finish!(status: 'succeeded')
      expect(run).not_to be_interrupted
      expect(run.display_status).to eq('succeeded')
    end
  end
end
