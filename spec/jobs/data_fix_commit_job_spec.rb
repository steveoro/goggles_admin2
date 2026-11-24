# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixCommitJob do
  let(:report) { FactoryBot.create(:ops_commit_report, source_path: '/tmp/results.new/242/spec-meeting-lt4.json', preflight: { 'drift_ack' => false }) }
  let(:ok_guards) { DataFix::Guards::Result.new(level: :ok, reasons: [], verdict: nil, acknowledged: false) }
  let(:ok_preflight) { Import::CommitPreflight::Result.new(errors: [], warnings: []) }
  let(:outcome) do
    DataFix::CommitRunner::Outcome.new(commit_state: 'committed', stats: { meetings_created: 1, errors: [] }, error_message: nil,
                                       archive_error: nil, script: nil, season_id: 242, done_dir: '/tmp/results.done/242',
                                       first_error_phase: nil, meeting_id: 19_001, log_full_path: '/tmp/x.log',
                                       health_run_ids: { 'results' => 1 }, db_generation_after: 3)
  end
  let(:runner) { instance_double(DataFix::CommitRunner, call: outcome) }

  before(:each) do
    allow(DataFix::Guards).to receive(:check).and_return(ok_guards)
    allow(Import::CommitPreflight).to receive(:new).and_return(instance_double(Import::CommitPreflight, call: ok_preflight))
    allow(DataFix::CommitRunner).to receive(:new).and_return(runner)
  end

  it 'runs on the pipeline queue with priority 0, under the local_db_writer concurrency key' do
    job = described_class.new(commit_report_id: 1)
    expect(job.queue_name).to eq('pipeline')
    expect(job.priority).to eq(0)
    expect(described_class.concurrency_limit).to eq(1)
    expect(job.concurrency_key).to end_with('local_db_writer')
  end

  it 'has no retry or discard handler' do
    expect(described_class.rescue_handlers).to be_empty
  end

  it 'commits a queued report and stores the outcome' do
    described_class.perform_now(commit_report_id: report.id)
    expect(DataFix::CommitRunner).to have_received(:new).with(hash_including(source_path: report.source_path, actor_user_id: report.requested_by_user_id))
    expect(report.reload).to have_attributes(status: 'committed', meeting_id: 19_001, done_dir: '/tmp/results.done/242',
                                             health_run_ids: { 'results' => 1 }, db_generation_after: 3)
    expect(report.stats).to include('meetings_created' => 1)
    expect(report.started_at).to be_present
    expect(report.finished_at).to be_present
  end

  it 'commits once when performed twice (the second perform finds the report not queued)' do
    2.times { described_class.perform_now(commit_report_id: report.id) }
    expect(runner).to have_received(:call).once
  end

  it 'refuses a report that is not queued' do
    report.update!(status: 'running')
    described_class.perform_now(commit_report_id: report.id)
    expect(runner).not_to have_received(:call)
    expect(report.reload.status).to eq('running')
  end

  it 'refuses a report without a requesting operator' do
    allow(Ops::CommitReport).to receive(:find_by).and_return(report)
    allow(report).to receive(:requested_by_user_id).and_return(nil)
    described_class.perform_now(commit_report_id: report.id)
    expect(runner).not_to have_received(:call)
    expect(report.reload.status).to eq('refused')
  end

  it 'never commits when the guards refuse (block, or a warning not acknowledged)' do
    allow(DataFix::Guards).to receive(:check)
      .and_return(DataFix::Guards::Result.new(level: :warn, reasons: ['unknown verdict'], verdict: nil, acknowledged: false))
    described_class.perform_now(commit_report_id: report.id)
    expect(runner).not_to have_received(:call)
    expect(report.reload).to have_attributes(status: 'refused')
    expect(report.error_message).to include('unknown verdict')
    expect(DataFix::Guards).to have_received(:check).with(:commit, acknowledged: false)
  end

  it 'passes the acknowledgement stored by the POST to the guards' do
    report.update!(preflight: { 'drift_ack' => true })
    described_class.perform_now(commit_report_id: report.id)
    expect(DataFix::Guards).to have_received(:check).with(:commit, acknowledged: true)
  end

  it 'never commits when the preflight finds an error' do
    allow(Import::CommitPreflight).to receive(:new)
      .and_return(instance_double(Import::CommitPreflight, call: Import::CommitPreflight::Result.new(errors: [{ code: 'x', message: 'dup team' }], warnings: [])))
    described_class.perform_now(commit_report_id: report.id)
    expect(runner).not_to have_received(:call)
    expect(report.reload.error_message).to include('dup team')
  end

  it 'never raises: an unexpected error closes the report as failed' do
    allow(runner).to receive(:call).and_raise(StandardError, 'kaboom')
    expect { described_class.perform_now(commit_report_id: report.id) }.not_to raise_error
    expect(report.reload).to have_attributes(status: 'failed')
    expect(report.error_message).to include('kaboom')
  end

  it 'never broadcasts on ImportStatusChannel (throttled ops progress instead)' do
    allow(ActionCable.server).to receive(:broadcast)
    described_class.perform_now(commit_report_id: report.id)
    expect(DataFix::CommitRunner).to have_received(:new).with(hash_including(progress: an_instance_of(Import::Progress::Ops)))
    expect(ActionCable.server).not_to have_received(:broadcast)
  end

  # Invariant: the commit job is enqueued only by an operator click (DataFix::CommitsController#commit_phase6): no
  # scheduler, planner, callback or other job calls it (comments and the inbox's protected-jobs list only name it).
  it 'is invoked only by the commits controller (and specs)' do
    invocation = /DataFixCommitJob\s*\.\s*(perform_later|perform_now|perform|set|new)\b/
    invoking = Rails.root.glob('{app,lib,config}/**/*.{rb,haml,erb,rake,yml}').select do |path|
      path.readlines.any? { |line| !line.strip.start_with?('#') && line.match?(invocation) }
    end
    expect(invoking.map { |path| path.relative_path_from(Rails.root).to_s }).to eq(['app/controllers/data_fix/commits_controller.rb'])
  end

  it 'is enqueued in exactly one place' do
    source = Rails.root.join('app/controllers/data_fix/commits_controller.rb').read
    expect(source.scan('DataFixCommitJob.perform_later').size).to eq(1)
  end

  it 'keeps the pipeline worker at 1 thread / 1 process (what serialises a commit and a prepare)' do
    config = YAML.safe_load(ERB.new(Rails.root.join('config/queue.yml').read).result, aliases: true)
    worker = config['production']['workers'].find { |row| row['queues'] == 'pipeline' }
    expect(worker).to include('threads' => 1, 'processes' => 1)
  end
end
