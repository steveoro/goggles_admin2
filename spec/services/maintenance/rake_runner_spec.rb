# frozen_string_literal: true

require 'rails_helper'

# Maintenance::RakeRunner in apply mode (simulate=0) and its stops; the simulate=1 output of every converted task is
# pinned by the rake parity specs (spec/tasks/*_parity_spec.rb). LocalDb::SqlRunner and Drift::Gate are stand-ins.
RSpec.describe Maintenance::RakeRunner do
  include ActiveJob::TestHelper
  include OutboxHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_runner')) }
  let(:out) { StringIO.new }

  before(:each) do
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    GogglesDb::Meeting.where(id: 1).update_all(code: 'parity-not-normalized') # rubocop:disable Rails/SkipsModelValidations
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def run_task(task_name, env, gate: maintenance_gate(:ok), sql_runner: maintenance_sql_runner, input: "\n")
    perform_enqueued_jobs do
      described_class.call(task_name, env:, out:, input: StringIO.new(input), data_root:, sql_runner:, gate:)
    end
  end

  def rake_runs = Ops::OperationRun.where(origin: 'rake').order(:id)

  it 'applies with simulate=0: dry run, gate, local apply, then the Outbox (pending, in local-apply order)' do
    status = run_task('normalize:coded_names', { 'limit' => '5', 'simulate' => '0' })
    expect(status).to be_nil
    expect(out.string).to include('- simulate.......: false', '--> Executing script...', '--> Done in 0.01 s.', "Done.\n")
    expect(out.string).to match(%r{File '#{data_root}/results\.new/misc/\d{4}-normalize_coded_names\.sql' saved \(Outbox: pending, seq \d+\)\.})
    expect(rake_runs.map(&:mode)).to eq(%w[preview apply])
    apply = rake_runs.last
    expect(apply).to have_attributes(status: 'succeeded', applied_locally: true, drift_ack: true, parent_run_id: rake_runs.first.id)
    expect(apply.sql_script).to have_attributes(state: 'pending', applied_locally: true, kind: 'normalize')
    expect(maintenance_sql_runs.size).to eq(1)
  end

  it 'stops before the apply on a red DB sync verdict (force=1 overrides it)' do
    expect(run_task('normalize:coded_names', { 'limit' => '5', 'simulate' => '0' }, gate: maintenance_gate(:block))).to be_nil
    expect(out.string).to include(I18n.t('db_sync.gate.rake_blocked', summary: '').split('(').first)
    expect(rake_runs.map(&:mode)).to eq(%w[preview])
    expect(maintenance_sql_runs).to be_empty
  end

  it 'prints the warning of an amber verdict and goes on (the operator at the terminal acknowledges it)' do
    run_task('normalize:coded_names', { 'limit' => '5', 'simulate' => '0' }, gate: maintenance_gate(:warn))
    expect(out.string).to include(I18n.t('db_sync.gate.rake_warning', summary: '').split('(').first)
    expect(rake_runs.last).to have_attributes(mode: 'apply', status: 'succeeded')
  end

  it 'exits 1 when the local apply fails: no Outbox script' do
    status = run_task('normalize:coded_names', { 'limit' => '5', 'simulate' => '0' }, sql_runner: maintenance_sql_runner(success: false, stderr: 'boom'))
    expect(status).to eq(1)
    expect(out.string).to include('boom', '*** ERROR: Script execution failed. Transaction rolled back. ***')
    expect(Dir.glob(data_root.join('results.new/**/*.sql').to_s)).to be_empty
  end

  it 'says that the script ran locally but was not registered when the Outbox write fails after the apply (kept SQL)' do
    write_sql_file(data_root, 'results.new/misc/0012-normalize_coded_names.sql', "-- someone else's file\n")
    status = run_task('normalize:coded_names', { 'limit' => '5', 'simulate' => '0', 'index' => '12' })
    expect(status).to eq(1)
    apply = rake_runs.last
    expect(apply).to have_attributes(mode: 'apply', status: 'failed', applied_locally: true, sql_script_id: nil)
    expect(out.string).to include(I18n.t('maintenance.rake.applied_unregistered', path: apply.unregistered_sql_path, folder: 'misc'))
    expect(out.string).not_to include('Transaction rolled back')
    expect(File.binread(apply.unregistered_sql_path)).to include('parity-not-normalized')
    expect(maintenance_sql_runs.size).to eq(1)
  ensure
    FileUtils.rm_f(apply&.unregistered_sql_path.to_s)
  end

  it 'says that nothing ran when a script-only write fails' do
    write_sql_file(data_root, 'results.new/misc/0012-normalize_coded_names.sql', "-- someone else's file\n")
    expect(run_task('normalize:coded_names', { 'limit' => '5', 'index' => '12' })).to eq(1)
    expect(out.string).to include(I18n.t('maintenance.rake.not_written').strip)
    expect(out.string).not_to include('Transaction rolled back')
  end

  it 'keeps the prompt between the plan and the script (an answer other than y stops with 0)' do
    meeting = GogglesDb::Meeting.find(18_222)
    expect(run_task('purge:meeting', { 'meeting' => meeting.id.to_s }, input: "n\n")).to eq(0)
    expect(out.string).to include('Purge Meeting Report', 'Proceed with generating purge script? [y/N] Aborted.')
    expect(rake_runs.map(&:mode)).to eq(%w[preview])
  end

  it 'needs the ops DB for the tasks writing a script' do
    allow(Ops).to receive(:available?).and_return(false)
    expect(run_task('normalize:coded_names', { 'limit' => '5' })).to eq(1)
    expect(out.string).to include(I18n.t('maintenance.rake.ops_unavailable'))
  end

  it 'has an adapter for every task of the conversion table' do
    expect(Maintenance::RakeTasks.task_names).to all(satisfy { |name| Maintenance::RakeTasks.fetch(name) < Maintenance::RakeTasks::Base })
    expect { Maintenance::RakeTasks.fetch('db:run') }.to raise_error(KeyError)
  end
end
