# frozen_string_literal: true

require 'rails_helper'

# Phase 14: every job class skips while a guided DB restore holds the lock (ApplicationJob around_perform ->
# DbRestore::JobGuard); only DbRestore::RestoreJob runs through it.
RSpec.describe DbRestore::JobGuard do
  after(:each) { Ops::Database.reset_state! }

  # Every named job class defined under app/jobs (also the ones of later phases).
  def app_job_classes
    jobs_dir = Rails.root.join('app/jobs').to_s
    Rails.autoloaders.main.eager_load_dir(jobs_dir)
    ActiveJob::Base.descendants.select do |job|
      job.name.present? && Object.const_source_location(job.name)&.first.to_s.start_with?(jobs_dir)
    end
  end

  it 'finds every job file and each class inherits ApplicationJob' do
    files = Rails.root.glob('app/jobs/**/*_job.rb').map { |path| path.relative_path_from(Rails.root.join('app/jobs')).to_s.delete_suffix('.rb').camelize }
    files -= ['ApplicationJob']
    classes = app_job_classes.reject { |job| job == ApplicationJob }
    expect(classes.map(&:name)).to match_array(files)
    expect(classes).to all(be < ApplicationJob)
  end

  describe 'while the lock is held' do
    let!(:run) { lock_with_run(status: 'loading') }

    it 'skips every job class but DbRestore::RestoreJob, recording an event' do
      ran = (app_job_classes - [ApplicationJob, DbRestore::RestoreJob]).select do |job_class|
        allow_any_instance_of(job_class).to receive(:perform).and_raise('must not run') # rubocop:disable RSpec/AnyInstance
        job_class.new.perform_now
        false
      rescue RuntimeError
        true
      end
      expect(ran).to be_empty
      events = Ops::Event.where(kind: 'db_restore.job_skipped')
      expect(events.count).to eq(app_job_classes.size - 2)
      expect(events.first.data).to include('job')
    end

    it 'lets DbRestore::RestoreJob run' do
      allow(DbRestore::Restorer).to receive(:new).and_return(instance_double(DbRestore::Restorer, call: true))
      DbRestore::RestoreJob.perform_now(run_id: run.id, mode: 'resume')
      expect(DbRestore::Restorer).to have_received(:new).with(hash_including(run:, mode: 'resume'))
    end
  end

  it 'runs the jobs (and checks the MySQL pool epoch) when no restore is in progress' do
    stub_const('SpecGuardJob', Class.new(ApplicationJob) { def perform = :ran })
    allow(DbRestore::Reconnect).to receive(:check!).and_call_original
    expect(SpecGuardJob.perform_now).to eq(:ran)
    expect(DbRestore::Reconnect).to have_received(:check!)
  end
end
