# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Restorer
  #
  # Orchestration of DbRestore::RestoreJob (wizard steps 6-7), one call per operator click:
  # - 'load'       (typed confirmation): confirmed -> loading; pause the queues, wait for the running jobs (up to
  #                DbRestore::DRAIN_TIMEOUT), re-check the preconditions (stage :load), capture (DbRestore::Preserver),
  #                load (DbRestore::Loader), post-steps (DbRestore::PostSteps);
  # - 'terminal'   (confirmation in terminal mode): the same preparation, then stops at step 'awaiting_terminal'
  #                (lock held) while the operator runs db:rebuild;
  # - 'post_steps' ("Load done, run post-steps"): checks the loaded schema_migrations and table list, then post-steps;
  # - 'resume'     ("Resume from load"): interrupted -> loading; load + post-steps again;
  # - 'snapshot'   ("Load safety snapshot"): interrupted -> loading; loads the safety snapshot + post-steps.
  # Until MySQL is touched a failure releases the lock (run 'failed', queues resumed); afterwards the run becomes
  # 'interrupted' and the lock stays (the progress page offers resume / snapshot / abandon).
  #
  class Restorer # rubocop:disable Metrics/ClassLength
    MODES = %w[load terminal post_steps resume snapshot].freeze
    CLAIMS = {
      'load' => %w[confirmed], 'terminal' => %w[confirmed], 'resume' => %w[interrupted loading post_steps],
      'snapshot' => %w[interrupted loading post_steps], 'post_steps' => %w[loading]
    }.freeze

    attr_reader :run, :mode

    # "Abandon" (progress page, rake db_restore:abandon): the run ends 'cancelled' and releases the lock, THEN the
    # queues it paused resume (a job claimed while the lock is held would be skipped). MySQL is left as it is.
    def self.abandon!(run, queues: DbRestore::Queues.new, via: 'web')
      run.update!(status: 'cancelled', step: 'abandoned', finished_at: Time.current)
      run.append_log!(I18n.t('db_restore.log.abandoned'))
      DbRestore::Lock.release!(run)
      queues.resume!(run.preserved.to_h['paused_queues'])
      Ops.record_event!(kind: 'db_restore.abandoned', level: 'warning', actor: 'operator', subject_type: 'restore_run',
                        subject_key: run.id, link_path: Rails.application.routes.url_helpers.db_restore_result_path(run),
                        data: { 'dump' => run.dump_basename, 'via' => via })
      run
    end

    # rubocop:disable-next Metrics/ParameterLists
    def initialize(run:, mode:, job_id: nil, target: DbRestore::Target.current, queues: DbRestore::Queues.new,
                   loader: nil, post_steps: nil, drain_timeout: DbRestore::DRAIN_TIMEOUT, poll_every: 2)
      raise ArgumentError, "unknown restore mode #{mode.inspect}" unless MODES.include?(mode.to_s)

      @run = run
      @mode = mode.to_s
      @job_id = job_id
      @target = target
      @queues = queues
      @loader = loader
      @post_steps = post_steps
      @drain_timeout = drain_timeout
      @poll_every = poll_every
      @touched = %w[resume snapshot post_steps].include?(@mode)
    end

    # Returns true when this call ran (false: the run was not in a claimable state, e.g. a duplicate perform).
    def call
      return false unless claim!

      DbRestore::Lock.acquire!(run)
      case mode
      when 'load', 'terminal' then prepare_and_load!
      when 'post_steps' then terminal_post_steps!
      when 'resume' then reload!(run.dump_path, from: 'dump')
      when 'snapshot' then reload!(run.snapshot_path, from: 'snapshot')
      end
      true
    rescue StandardError => e
      handle_failure(e)
      true
    end

    private

    def claim! # rubocop:disable Naming/PredicateMethod
      attributes = { error: nil }
      attributes[:job_id] = @job_id if @job_id
      attributes[:started_at] = Time.current if run.started_at.nil?
      attributes[:step] = 'verify' if mode == 'post_steps'
      from_step = mode == 'post_steps' ? Ops::RestoreRun::AWAITING_TERMINAL : nil
      return true if run.claim!(from: CLAIMS.fetch(mode), to: 'loading', from_step:, **attributes)

      Rails.logger.warn("[DbRestore::Restorer] run #{run.id} is #{run.status}: '#{mode}' refused")
      false
    end

    def prepare_and_load!
      pause_and_drain!
      DbRestore::Preserver.capture!(run)
      return await_terminal! if mode == 'terminal'

      @touched = true
      loader.call(run.dump_path)
      run.record_outcome!('loaded_from' => 'dump')
      post_steps.call
    end

    def pause_and_drain!
      run.step!(:pause)
      remember_paused(@queues.pause!(DbRestore::PAUSED_QUEUES))
      run.step!(:drain)
      wait_for_drain
      result = DbRestore::Preconditions.new(run:, target: @target, queues: @queues, own_job_ids: [@job_id]).call(stage: :load)
      raise Refused, result.messages.join(' • ') unless result.allowed?
    end

    # Keeps the queues paused by this run (only those are resumed afterwards).
    def remember_paused(names)
      preserved = run.preserved.to_h
      run.update!(preserved: preserved.merge('paused_queues' => (Array(preserved['paused_queues']) + names).uniq))
    end

    def wait_for_drain
      deadline = Time.current + @drain_timeout
      loop do
        break if running_jobs.empty? || Time.current >= deadline

        run.heartbeat!
        sleep(@poll_every)
      end
    end

    def running_jobs
      @queues.claimed(except_job_ids: [@job_id]).reject { |job| DbRestore::OWN_JOBS.include?(job.class_name) }
    end

    def await_terminal!
      run.update!(step: Ops::RestoreRun::AWAITING_TERMINAL)
      run.append_log!(I18n.t('db_restore.steps.awaiting_terminal'))
    end

    # After the operator's db:rebuild: the loaded DB must have the core tables and a schema_migrations version.
    def terminal_post_steps!
      run.append_log!(I18n.t('db_restore.steps.verify'))
      ActiveRecord::Base.connection_pool.disconnect!
      conn = ActiveRecord::Base.connection_pool.lease_connection
      missing = DbRestore::CORE_TABLES - conn.tables
      version = missing.include?('schema_migrations') ? nil : conn.select_values('SELECT version FROM schema_migrations').map(&:to_s).max
      raise Refused, I18n.t('db_restore.errors.terminal_verify', missing: missing.join(', ').presence || '-') if missing.any? || version.blank?

      run.record_outcome!('loaded_from' => 'terminal')
      post_steps.call
    end

    def reload!(path, from:)
      raise Refused, I18n.t('db_restore.errors.dump_missing', path: path.to_s) unless File.file?(path.to_s)

      remember_paused(@queues.pause!(DbRestore::PAUSED_QUEUES))
      loader.call(path)
      run.record_outcome!('loaded_from' => from)
      post_steps.call
    end

    def loader
      @loader ||= DbRestore::Loader.new(run:, target: @target)
    end

    def post_steps
      @post_steps ||= DbRestore::PostSteps.new(run:, queues: @queues)
    end

    # rubocop:disable-next Metrics/AbcSize
    def handle_failure(error)
      run.reload
      message = DbRestore.scrub(error.is_a?(Refused) || error.is_a?(CommandFailed) ? error.message : "#{error.class}: #{error.message}",
                                secrets: [run.preserved.to_h['jwt']])
      Rails.logger.error("[DbRestore::Restorer] run #{run.id} (#{mode}): #{message}")
      if awaiting_terminal_refusal?(error)
        run.update!(step: Ops::RestoreRun::AWAITING_TERMINAL, error_text: message)
      elsif @touched
        run.update!(status: 'interrupted', error_text: message)
        record_event('db_restore.interrupted', 'error', message)
      else
        # (Lock released before the queues resume: a job claimed while it is held is skipped.)
        run.update!(status: 'failed', error_text: message, finished_at: Time.current)
        DbRestore::Lock.release!(run)
        @queues.resume!(run.preserved.to_h['paused_queues'])
        record_event('db_restore.failed', 'error', message)
      end
      run.append_log!(I18n.t('db_restore.log.failed', error: message.truncate(300)))
    rescue StandardError => e
      Rails.logger.error(DbRestore.scrub("[DbRestore::Restorer] run #{run.id}: failure handling failed: #{e.class}: #{e.message}"))
    end

    # A failed check after a terminal load leaves the run waiting for a fixed db:rebuild.
    def awaiting_terminal_refusal?(error)
      mode == 'post_steps' && error.is_a?(Refused) && !run.post_steps?
    end

    def record_event(kind, level, message)
      Ops.record_event!(kind:, level:, actor: 'operator', subject_type: 'restore_run', subject_key: run.id,
                        data: { 'mode' => mode, 'error' => message.truncate(300) },
                        link_path: Rails.application.routes.url_helpers.db_restore_result_path(run))
    end
  end
end
