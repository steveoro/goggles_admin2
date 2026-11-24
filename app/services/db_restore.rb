# frozen_string_literal: true

#
# = DbRestore
#
# Guided restore of the local MySQL development DB from a production dump (phase 14, see docs/db_restore.md).
#
# Wizard (DbRestoreController): preconditions (DbRestore::Preconditions) -> dump choice (DbRestore::DumpCatalog)
# -> inspection (DbRestore::InspectJob, DbRestore::DumpInspector) -> safety snapshot (DbRestore::SnapshotJob,
# DbRestore::Snapshot) -> typed confirmation -> load + post-steps (DbRestore::RestoreJob, DbRestore::Restorer:
# DbRestore::Preserver, DbRestore::Loader, DbRestore::PostSteps) -> result. Every row lives in the ops DB
# (Ops::RestoreRun), which a restore never touches.
#
# While a run holds DbRestore::Lock every page answers "restore in progress" (DbRestoreGuard) and every job but
# DbRestore::RestoreJob skips (DbRestore::JobGuard, from ApplicationJob).
#
module DbRestore
  # Solid Queue queues paused by the restore (the 'maintenance' worker runs the wizard's own jobs: its other jobs
  # skip through the lock).
  PAUSED_QUEUES = %w[default background pipeline outbox].freeze
  # Running jobs (claimed executions) that make the wizard refuse to start (class names: the classes of later
  # phases may not exist yet).
  BLOCKING_JOBS = %w[DataFixCommitJob Maintenance::RunJob Health::SeasonRunJob Health::SweepJob].freeze
  # Queued (not yet running) jobs that make the wizard refuse: each one has a run row (commit report, operation run,
  # health run) that would stay 'queued' if the job were skipped through the lock. (Health::SweepJob is recurring and
  # stateless: a skipped sweep simply runs next time.)
  QUEUED_BLOCKING_JOBS = %w[DataFixCommitJob Maintenance::RunJob Health::SeasonRunJob].freeze
  # The wizard's own jobs (never waited for).
  OWN_JOBS = %w[DbRestore::InspectJob DbRestore::SnapshotJob DbRestore::RestoreJob].freeze
  # How long the load waits for the running jobs to finish after pausing the queues.
  DRAIN_TIMEOUT = 10.minutes
  # Tables a production dump must contain.
  CORE_TABLES = %w[
    schema_migrations ar_internal_metadata users admin_grants app_parameters settings seasons meetings
    meeting_sessions meeting_events meeting_programs meeting_individual_results swimmers teams badges laps
    import_queues data_import_meeting_individual_results
  ].freeze

  # Raised when a step refuses to go on (message shown to the operator).
  class Refused < StandardError; end
  # Raised when an external command fails (message: the command's error output, never a credential).
  class CommandFailed < StandardError; end

  # Anything shaped like a JWT (three base64url segments, header '{"...'), replaced by #scrub.
  JWT_LIKE = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/
  FILTERED = '[FILTERED]'

  # +text+ without API tokens (a JWT-like value, and each of +secrets+): for every error text stored, logged or shown.
  def self.scrub(text, secrets: [])
    scrubbed = text.to_s.gsub(JWT_LIKE, FILTERED)
    Array(secrets).compact_blank.each { |secret| scrubbed = scrubbed.gsub(secret.to_s, FILTERED) }
    scrubbed
  end

  # Runs the block with the SQL log silenced (statements carrying the operator's API token), returning its value.
  def self.without_sql_log(&)
    logger = ActiveRecord::Base.logger
    logger.respond_to?(:silence) ? logger.silence(&) : yield
  end

  # Every migration version known to the local code (Strings, sorted): the goggles_db engine's db/migrate plus the
  # app's own (empty in admin2).
  def self.local_schema_versions
    [GogglesDb::Engine.root.join('db/migrate'), Rails.root.join('db/migrate')]
      .flat_map { |dir| Dir.glob(dir.join('*.rb').to_s) }
      .filter_map { |path| File.basename(path)[/\A(\d{14})_/, 1] }
      .uniq.sort
  end

  # Newest migration version known to the local code (String), or nil.
  def self.local_schema_version
    local_schema_versions.last
  end
end
