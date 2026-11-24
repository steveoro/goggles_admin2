# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::RunJob do
  it 'runs on the maintenance queue, before the health runs' do
    expect(described_class.new.queue_name).to eq('maintenance')
    expect(described_class.new.priority).to be < Health::SeasonRunJob::PRIORITY_ON_DEMAND
  end

  it 'has no retry nor discard handler' do
    expect(described_class.rescue_handlers).to be_empty
  end

  it 'inherits ApplicationJob (the DB restore guard of phase 14 covers it)' do
    expect(described_class.superclass).to eq(ApplicationJob)
  end

  it 'shares the local_db_writer concurrency key with the Data-Fix commit job in apply mode only' do
    apply_key = described_class.new(run_id: 3, mode: 'apply').concurrency_key
    expect(apply_key).to eq(DataFixCommitJob.new(commit_report_id: 9).concurrency_key)
    expect(apply_key).to eq('local_db_writer/local_db_writer')
    expect(described_class.new(run_id: 3, mode: 'preview').concurrency_key).not_to eq(apply_key)
    expect(described_class.concurrency_limit).to eq(1)
  end

  it 'is enqueued only by the operations controllers' do
    sites = Rails.root.glob('{app,lib,config}/**/*.{rb,rake,haml}').filter_map do |file|
      code = file.read.lines.reject { |line| line.strip.start_with?('#') }.join
      file.relative_path_from(Rails.root).to_s if code.match?(/Maintenance::RunJob\.(?:perform_later|perform_now|set|new)|RunJob\.perform_later/)
    end
    expect(sites).to eq(['app/controllers/maintenance/runs_controller.rb'])
  end

  it 'runs the Executor on the queued run' do
    run = FactoryBot.create(:ops_operation_run, mode: 'preview')
    executor = instance_double(Maintenance::Executor, call: run)
    allow(Maintenance::Executor).to receive(:new).and_return(executor)
    described_class.perform_now(run_id: run.id, mode: 'preview')
    expect(Maintenance::Executor).to have_received(:new).with(run:)
    expect(executor).to have_received(:call)
  end

  it 'refuses a mode that does not match the run, and ignores an unknown run' do
    run = FactoryBot.create(:ops_operation_run, mode: 'preview')
    described_class.perform_now(run_id: run.id, mode: 'apply')
    expect(run.reload).to have_attributes(status: 'refused', refusal_reason: 'mode_mismatch')
    expect { described_class.perform_now(run_id: 0, mode: 'apply') }.not_to raise_error
  end
end
