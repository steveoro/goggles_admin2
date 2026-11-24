# frozen_string_literal: true

module Ops
  #
  # = Ops::RestoreRun
  #
  # One guided restore of the local MySQL DB from a production dump (ops DB, table 'restore_runs'; phase 14, see
  # DbRestoreController and DbRestore). The table is also the restore history.
  #
  # == Statuses
  #   inspecting -> ready | failed            (DbRestore::InspectJob)
  #   ready -> snapshotting -> ready          (DbRestore::SnapshotJob: the safety snapshot, step 'snapshot_done'
  #                                            or 'snapshot_failed')
  #   ready -> confirmed                      (typed confirmation: DbRestore::Lock acquired)
  #   confirmed -> loading -> post_steps -> finished   (DbRestore::RestoreJob)
  #   confirmed -> failed                     (refused before touching MySQL: lock released)
  #   loading | post_steps -> interrupted     (error after the drop: the lock stays)
  #   interrupted -> loading                  ("Resume from load", "Load safety snapshot")
  #   inspecting | ready | snapshotting -> cancelled   (Cancel)
  #   confirmed | loading | post_steps | interrupted -> cancelled   (Abandon, typed DB name: lock released)
  # 'draft' is reserved (a run is created already 'inspecting').
  #
  # == Attributes
  # - mode: 'wizard' (the job loads the dump) or 'terminal' (the operator loads it with db:rebuild, then clicks
  #   "Load done, run post-steps"); step: current step key (texts 'db_restore.steps.<step>');
  # - dump_*: the chosen dump and what DbRestore::DumpInspector read from it; inspection: the inspector's details
  #   (header, warnings, errors, Outbox scripts newer than the dump, the dump's API URL);
  # - snapshot_path / ops_backup_path: the safety snapshot of the MySQL DB and the ops DB backup;
  # - confirmations: the operator's ticks ('discard_reviews', 'skip_snapshot', 'api_url_choice', 'typed_name');
  # - preserved: what DbRestore::Preserver keeps across the load ('api_url', 'user_id', 'jwt' until re-applied,
  #   'paused_queues'); outcome: the post-step results; progress_bytes: compressed bytes read by the load;
  # - log (LOG_LIMIT, newest kept), error; job_id; progress_token_digest (SHA-256 of the progress page token).
  #
  class RestoreRun < ApplicationRecord
    self.table_name = 'restore_runs'

    STATUSES = %w[
      draft inspecting ready snapshotting confirmed loading post_steps finished failed interrupted cancelled
    ].freeze
    # Statuses holding DbRestore::Lock (MySQL may be gone).
    LOCKING_STATUSES = %w[confirmed loading post_steps interrupted].freeze
    TERMINAL_STATUSES = %w[finished failed cancelled].freeze
    OPEN_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
    # Before the typed confirmation (the run can still be cancelled).
    PREPARING_STATUSES = %w[draft inspecting ready snapshotting].freeze
    MODES = %w[wizard terminal].freeze
    LOG_LIMIT = 64.kilobytes
    ERROR_LIMIT = 8.kilobytes
    # A load or post-step run without a heartbeat for this long is shown as interrupted (the worker died).
    STALLED_AFTER = 2.minutes
    # Step of a terminal-mode run waiting for the operator's db:rebuild.
    AWAITING_TERMINAL = 'awaiting_terminal'

    # (The preserved values may hold the operator's API token until re-applied: never shown by inspect / logged binds.)
    self.filter_attributes += %w[preserved progress_token_digest]

    validates :status, inclusion: { in: STATUSES }
    validates :mode, inclusion: { in: MODES }

    # A run that ended (finished, failed, cancelled / abandoned) never keeps the operator's API token.
    before_save :drop_preserved_jwt, if: -> { terminal? && preserved.to_h.key?('jwt') }
    # A save writing the token runs with the SQL log silenced (no bind value of it in the log).
    around_save :silence_token_sql, if: -> { will_save_change_to_preserved? && preserved.to_h.key?('jwt') }

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :open_runs, -> { where(status: OPEN_STATUSES) }

    STATUSES.each do |name|
      define_method(:"#{name}?") { status == name }
    end

    def locking? = LOCKING_STATUSES.include?(status)
    def terminal? = TERMINAL_STATUSES.include?(status)
    def preparing? = PREPARING_STATUSES.include?(status)
    def terminal_mode? = mode == 'terminal'
    def awaiting_terminal? = loading? && step == AWAITING_TERMINAL

    # True for a load / post-step run whose heartbeat stopped (the worker process died).
    def stalled?(now: Time.current)
      return false unless loading? || post_steps?
      return false if awaiting_terminal?

      updated_at.present? && updated_at < now - STALLED_AFTER
    end

    # The run must be resumed / rolled back / abandoned by the operator.
    def needs_operator?(now: Time.current)
      interrupted? || stalled?(now:)
    end

    # Load progress in percent of the compressed dump (0..100), or nil when the size is unknown.
    def progress_percent
      return nil unless dump_bytes.to_i.positive?

      [(progress_bytes.to_i * 100.0 / dump_bytes).round(1), 100.0].min
    end

    def ticked?(key)
      confirmations.to_h[key.to_s] == true
    end

    def dump_basename
      dump_path.present? ? File.basename(dump_path.to_s) : nil
    end

    # The dump name db:rebuild expects ('from=<name>': the basename without '.sql.bz2').
    def dump_rebuild_name
      dump_basename&.delete_suffix('.sql.bz2')
    end

    def snapshot_exists?
      snapshot_path.present? && File.file?(snapshot_path.to_s)
    end

    # Generates the one-time progress page token: stores its digest and returns it (shown once, kept in the session).
    def issue_token!
      token = SecureRandom.urlsafe_base64(24)
      update!(progress_token_digest: self.class.token_digest(token))
      token
    end

    def token_matches?(token)
      return false if token.blank? || progress_token_digest.blank?

      ActiveSupport::SecurityUtils.secure_compare(progress_token_digest, self.class.token_digest(token.to_s))
    end

    def self.token_digest(token)
      Digest::SHA256.hexdigest(token.to_s)
    end

    # Moves the run from one of +from+ to +to+ with a conditional update (a duplicate perform moves it once);
    # returns true when this call moved it.
    # +from_step+: also require that step (e.g. AWAITING_TERMINAL).
    def claim!(from:, to:, from_step: nil, **attributes) # rubocop:disable Naming/PredicateMethod
      now = Time.current
      scope = self.class.where(id:, status: Array(from))
      scope = scope.where(step: from_step) if from_step
      moved = scope.update_all(attributes.merge(status: to, updated_at: now)) # rubocop:disable Rails/SkipsModelValidations
      reload
      moved == 1
    end

    # Appends a timestamped line to the log (keeps the newest LOG_LIMIT bytes; API tokens scrubbed).
    def append_log!(line)
      text = "#{log}[#{Time.current.utc.strftime('%H:%M:%S')}] #{scrub(line).squish.truncate(500)}\n"
      text = text.byteslice(text.bytesize - LOG_LIMIT, LOG_LIMIT).to_s.scrub('') if text.bytesize > LOG_LIMIT
      update!(log: text)
    end

    # Current step + log line.
    def step!(key, message = nil)
      update!(step: key.to_s)
      append_log!(message || I18n.t("db_restore.steps.#{key}", default: key.to_s))
    end

    # Heartbeat of a running load: progress bytes and updated_at, without callbacks (called every few seconds).
    def heartbeat!(bytes = progress_bytes)
      update_columns(progress_bytes: bytes.to_i, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Stores the error text with any API token scrubbed (DbRestore.scrub).
    def error_text=(value)
      self.error = scrub(value).truncate(ERROR_LIMIT)
    end

    # +text+ without the preserved token nor anything shaped like a JWT.
    def scrub(text)
      DbRestore.scrub(text, secrets: [preserved.to_h['jwt']])
    end

    # Merges +values+ into the outcome Hash and saves.
    def record_outcome!(values)
      update!(outcome: outcome.to_h.merge(values.deep_stringify_keys))
    end

    # The (decoded) inspection detail +key+.
    def inspection_value(key)
      inspection.to_h[key.to_s]
    end

    private

    def silence_token_sql(&)
      DbRestore.without_sql_log(&)
    end

    def drop_preserved_jwt
      self.preserved = preserved.to_h.except('jwt').merge('jwt_dropped_at' => Time.current.utc.iso8601)
    end
  end
end
