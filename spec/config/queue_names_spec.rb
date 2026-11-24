# frozen_string_literal: true

require 'rails_helper'

# Solid Queue picks up only the queues listed by a worker of config/queue.yml: a job enqueued on any
# other queue would wait forever, silently. Every job of app/jobs and every recurring task must be served.
RSpec.describe 'Solid Queue queue names' do # rubocop:disable RSpec/DescribeClass
  let(:env) { 'production' }

  # Queue names served by the workers of config/queue.yml for +env+ ('*' serves everything).
  def served_queues(env)
    config = YAML.safe_load(ERB.new(Rails.root.join('config/queue.yml').read).result, aliases: true)
    workers = Array((config[env] || config['default'])['workers'])
    workers.flat_map { |worker| worker['queues'].to_s.split(',') }.map(&:strip).compact_blank.uniq
  end

  # Recurring task definitions of config/recurring.yml for +env+ (task name => Hash).
  def recurring_tasks(env)
    config = YAML.safe_load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    config[env] || config['default'] || {}
  end

  # The named job classes defined under app/jobs.
  def app_jobs
    jobs_dir = Rails.root.join('app/jobs').to_s
    Rails.autoloaders.main.eager_load_dir(jobs_dir)
    ApplicationJob.descendants.select do |job|
      job.name.present? && Object.const_source_location(job.name)&.first.to_s.start_with?(jobs_dir)
    end
  end

  # Queue of a job class name (nil when blank).
  def job_queue(class_name)
    class_name.present? ? class_name.constantize.new.queue_name : nil
  end

  def served?(queue, served)
    served.include?('*') || served.include?(queue.to_s)
  end

  it 'has a worker for the default, background, maintenance, outbox and pipeline queues' do
    expect(served_queues(env)).to include('default', 'background', 'maintenance', 'outbox', 'pipeline')
  end

  it 'serves the queue of every job under app/jobs' do
    served = served_queues(env)
    jobs = app_jobs
    expect(jobs).to include(KpiRefreshJob, SeasonRecheckJob, Health::SeasonRunJob, Health::SweepJob, Outbox::PushJob,
                            Outbox::RemoteStatusJob, Outbox::ImportLegacyJob, DataFixCommitJob, DataFixPrepareJob, PipelinePlannerJob,
                            SourceCrawlJob, PdfScanJob)
    unserved = jobs.reject { |job| served?(job.new.queue_name, served) }.map { |job| "#{job.name} (#{job.new.queue_name})" }
    expect(unserved).to be_empty, "queues without a worker in config/queue.yml: #{unserved.join(', ')}"
  end

  it 'serves the queue of every recurring task, explicit or inherited from its job class' do
    served = served_queues(env)
    tasks = recurring_tasks(env)
    expect(tasks).not_to be_empty
    unserved = tasks.filter_map do |name, task|
      queue = task['queue'].presence || job_queue(task['class'])
      next if queue.blank? || served?(queue, served)

      "#{name} (#{queue})"
    end
    expect(unserved).to be_empty, "recurring tasks on a queue without a worker: #{unserved.join(', ')}"
  end

  it 'references only existing job classes in the recurring tasks' do
    classes = recurring_tasks(env).values.filter_map { |task| task['class'] }
    expect(classes.reject { |name| name.safe_constantize&.<(ActiveJob::Base) }).to be_empty
  end

  it 'uses the same workers in every environment' do
    expect(%w[development test staging].map { |name| served_queues(name) }).to all(match_array(served_queues(env)))
  end
end
