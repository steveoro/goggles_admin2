# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'DbRestore inspect and snapshot jobs' do # rubocop:disable RSpec/DescribeClass
  let(:fixture) { Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2').to_s }

  after(:each) { Ops::Database.reset_state! }

  describe DbRestore::InspectJob do
    it 'stores the inspection and makes the run ready' do
      run = create_restore_run(status: 'inspecting', dump_path: fixture)
      described_class.perform_now(run_id: run.id)
      expect(run.reload).to have_attributes(status: 'ready', step: 'inspected', dump_iq_next_id: 9124, dump_sha256: Digest::SHA256.file(fixture).hexdigest)
      expect(run.dump_tables).to include('users', 'import_queues')
      expect(run.inspection).to include('header_line' => '-- /app/db/dump/production.sql', 'api_url' => 'https://api.example.test')
    end

    it 'fails the run with the reasons for a refused dump' do
      run = create_restore_run(status: 'inspecting', dump_path: '/nope/production-1.sql.bz2')
      described_class.perform_now(run_id: run.id)
      expect(run.reload).to have_attributes(status: 'failed', step: 'inspect_failed')
      expect(run.error).to eq(I18n.t('db_restore.inspection.errors.missing', detail: ''))
    end

    it 'ignores a run that is not inspecting' do
      run = create_restore_run(status: 'cancelled')
      described_class.perform_now(run_id: run.id)
      expect(run.reload.status).to eq('cancelled')
    end
  end

  describe DbRestore::SnapshotJob do
    let(:run) { create_restore_run(status: 'snapshotting') }

    it 'takes the snapshot and makes the run ready again' do
      snapshot = instance_double(DbRestore::Snapshot, call: '/tmp/development-0432-pre-restore.sql.bz2')
      allow(DbRestore::Snapshot).to receive(:new).and_return(snapshot)
      described_class.perform_now(run_id: run.id)
      expect(run.reload).to have_attributes(status: 'ready', step: 'snapshot_done')
    end

    it 'keeps the run ready with the error when the snapshot fails' do
      snapshot = instance_double(DbRestore::Snapshot)
      allow(snapshot).to receive(:call).and_raise(DbRestore::Refused, 'Not enough free space')
      allow(DbRestore::Snapshot).to receive(:new).and_return(snapshot)
      described_class.perform_now(run_id: run.id)
      expect(run.reload).to have_attributes(status: 'ready', step: 'snapshot_failed', error: 'Not enough free space')
    end
  end
end
