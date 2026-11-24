# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Preconditions
  #
  # Wizard steps 0-1: the checklist a restore must pass, re-evaluated at each stage.
  # - :entry   (GET new / POST create) and :confirm (the typed confirmation): everything below except the drain;
  # - :load    (DbRestore::Restorer, after pausing the queues and waiting): also "every running job finished".
  #
  # Checks (key => refused when):
  # - environment / host / database_name: DbRestore::Target guards (development env, local host, development DB name);
  # - ops: the ops DB is not available (the lock and the history live there);
  # - other_run: another run is open (any status but finished / failed / cancelled);
  # - outbox: a script is pending, held, pushing, sent, in_doubt or failed (push, withdraw or discard it first: the
  #   restore would lose its local changes or leave its server row behind);
  # - push_run: a push run is live;
  # - blocking_jobs: a DataFixCommitJob, Maintenance::RunJob, Health::SeasonRunJob or Health::SweepJob is running, or
  #   one of DbRestore::QUEUED_BLOCKING_JOBS is queued (skipped through the lock, its run row would stay 'queued');
  # - reviews: Data-Fix sources with phase files or staging rows exist and the operator did not tick
  #   'discard_reviews' (their staging rows are purged and their matches go stale);
  # - queue_db: (warning) the Solid Queue DB can't be read, so the queues can't be paused;
  # - drain: (:load only) a job other than the restore's own is still running.
  # Informational: running_jobs (other running jobs, waited for up to DbRestore::DRAIN_TIMEOUT by the load).
  #
  class Preconditions
    STAGES = %i[entry confirm load].freeze
    # Outbox states that block a restore.
    BLOCKING_SCRIPT_STATES = %w[pending held pushing sent in_doubt failed].freeze
    ITEMS_LISTED = 20

    # One check: +key+, +level+ (:ok, :refused, :warning, :info), +detail+ (String or nil), +items+ (Strings).
    Check = Data.define(:key, :level, :detail, :items) do
      def ok? = level == :ok
      def refused? = level == :refused
      def warning? = level == :warning
    end

    Result = Data.define(:stage, :checks) do
      def allowed? = checks.none?(&:refused?)
      def refused = checks.select(&:refused?)
      def [](key) = checks.find { |check| check.key == key.to_sym }

      # One translated line per refused check.
      def messages
        refused.map { |check| I18n.t("db_restore.checks.#{check.key}.refused", detail: check.detail.to_s) }
      end
    end

    # == Params
    # - run: the Ops::RestoreRun being checked (left out of 'other_run'; its own job left out of the drain);
    # - confirmations: the operator's ticks (default: the run's); target, queues, session_index: collaborators.
    # rubocop:disable-next Metrics/ParameterLists
    def initialize(run: nil, confirmations: nil, target: DbRestore::Target.current, queues: DbRestore::Queues.new,
                   session_index: nil, own_job_ids: [])
      @run = run
      @confirmations = (confirmations || run&.confirmations || {}).to_h.stringify_keys
      @target = target
      @queues = queues
      @session_index = session_index
      @own_job_ids = Array(own_job_ids)
    end

    def call(stage: :entry)
      raise ArgumentError, "unknown stage #{stage.inspect}" unless STAGES.include?(stage.to_sym)

      checks = target_checks + [ops_check]
      checks += ops_checks if checks.last.ok?
      checks += job_checks(stage.to_sym)
      checks << reviews_check
      Result.new(stage: stage.to_sym, checks:)
    end

    private

    def target_checks
      @target.checks.map { |check| build(check.key, check.ok? ? :ok : :refused, detail: check.detail) }
    end

    def ops_check
      build(:ops, Ops.available? ? :ok : :refused, detail: Ops.state.to_s)
    end

    def ops_checks
      [other_run_check, outbox_check, push_run_check]
    end

    def other_run_check
      others = Ops.safely([]) { Ops::RestoreRun.open_runs.where.not(id: @run&.id).recent.limit(ITEMS_LISTED).to_a }
      return build(:other_run, :ok) if others.empty?

      build(:other_run, :refused, detail: others.map { |run| "##{run.id}" }.join(', '),
                                  items: others.map { |run| "##{run.id} #{run.status}" })
    end

    def outbox_check
      scripts = Ops.safely([]) do
        Ops::SqlScript.in_state(BLOCKING_SCRIPT_STATES).ordered.limit(ITEMS_LISTED).pluck(:filename, :state)
      end
      return build(:outbox, :ok) if scripts.empty?

      build(:outbox, :refused, detail: scripts.size.to_s, items: scripts.map { |filename, state| "#{filename} (#{state})" })
    end

    def push_run_check
      runs = Ops.safely([]) { Ops::PushRun.running.limit(ITEMS_LISTED).pluck(:id) }
      return build(:push_run, :ok) if runs.empty?

      build(:push_run, :refused, detail: runs.map { |id| "##{id}" }.join(', '))
    end

    def job_checks(stage)
      return [build(:queue_db, :warning)] unless @queues.available?

      running = @queues.claimed(except_job_ids: @own_job_ids).reject { |job| DbRestore::OWN_JOBS.include?(job.class_name) }
      blocking = running.select { |job| DbRestore::BLOCKING_JOBS.include?(job.class_name) }
      checks = [blocking_check(blocking, @queues.queued(class_names: DbRestore::QUEUED_BLOCKING_JOBS))]
      others = running - blocking
      if stage == :load
        checks << (others.empty? ? build(:drain, :ok) : build(:drain, :refused, detail: job_names(others), items: job_items(others)))
      elsif others.any?
        checks << build(:running_jobs, :info, detail: job_names(others), items: job_items(others))
      end
      checks
    end

    def blocking_check(running, queued)
      return build(:blocking_jobs, :ok) if running.empty? && queued.empty?

      items = job_items(running) + queued.first(ITEMS_LISTED).map do |job|
        I18n.t('db_restore.checks.blocking_jobs.queued_item', job: "#{job.class_name} (#{job.queue_name})")
      end
      build(:blocking_jobs, :refused, detail: job_names(running + queued), items:)
    end

    def reviews_check
      sources = review_sources
      return build(:reviews, :ok) if sources.empty?

      level = @confirmations['discard_reviews'] == true ? :info : :refused
      build(:reviews, level, detail: sources.size.to_s, items: sources.first(ITEMS_LISTED))
    end

    # Data-Fix sources in progress: phase files in results.new and/or staging rows.
    def review_sources
      index = @session_index || DataFix::SessionIndex.new
      index.rows.map do |row|
        row.staging? ? "#{row.name} (#{I18n.t('db_restore.checks.reviews.staging_rows', count: row.staging_rows)})" : row.name
      end
    rescue StandardError => e
      Rails.logger.warn("[DbRestore::Preconditions] reviews: #{e.class}: #{e.message}")
      []
    end

    def job_names(jobs)
      jobs.map(&:class_name).tally.map { |name, count| count > 1 ? "#{name} ×#{count}" : name }.join(', ')
    end

    def job_items(jobs)
      jobs.first(ITEMS_LISTED).map { |job| "#{job.class_name} (#{job.queue_name})" }
    end

    def build(key, level, detail: nil, items: [])
      Check.new(key:, level:, detail:, items:)
    end
  end
end
