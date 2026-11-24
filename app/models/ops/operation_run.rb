# frozen_string_literal: true

module Ops
  #
  # = Ops::OperationRun
  #
  # One run of a maintenance operation (ops DB, table 'operation_runs', phase 11; see Maintenance::Executor):
  # - 'preview': the dry run (Maintenance::Operation#plan): console output, summary, warnings, errors, SQL preview and
  #   the SQL digest; writes nothing else;
  # - 'apply': child of a succeeded preview (+parent_run_id+): re-plans on live data, refuses a changed digest, runs the
  #   SQL on the local DB (LocalDb::SqlRunner) and only then registers the script in the Outbox (+sql_script_id+);
  # - 'script_only': rake only (phase 13): registers the script held 'not_applied_locally', nothing run locally.
  #
  # Created only by the operations controllers (operator clicks) or a rake caller; run by Maintenance::RunJob (or inline
  # by a rake task). No MySQL table is involved: the history lives here.
  #
  # == Attributes
  # - operation_key (Maintenance::Registry key), params (JSON Hash), params_digest, mode (MODES), parent_run_id;
  # - status (STATUSES), refusal_reason (REFUSAL_REASONS), label (the plan label);
  # - console (captured stdout, capped at CONSOLE_LIMIT), summary (Hash), warnings / error_messages (Arrays of Strings);
  # - sql_preview (capped at SQL_PREVIEW_LIMIT), sql_digest (Maintenance::Plan#digest), applied_locally, sql_script_id;
  # - season_id, subject_type, subject_id, origin (ORIGINS), health_finding_id;
  # - drift_ack (the operator's DB sync tick), drift_verdict (verdict name seen by the apply);
  # - started_by (user id), job_id, started_at, finished_at.
  #
  # (The column is +error_messages+, not +errors+: ActiveModel owns #errors.)
  #
  class OperationRun < ApplicationRecord
    self.table_name = 'operation_runs'

    MODES = %w[preview apply script_only].freeze
    STATUSES = %w[queued running succeeded failed refused].freeze
    PENDING_STATUSES = %w[queued running].freeze
    ORIGINS = %w[ui rake health commit_report].freeze
    REFUSAL_REASONS = %w[restore_in_progress disabled no_preview already_applied drift_blocked drift_unacknowledged
                         digest_changed blocked empty mode_mismatch unknown_operation].freeze
    # A queued/running run whose job state is unknown (see Maintenance::JobState) counts as interrupted after this long;
    # with a known live job, only after the job's concurrency duration (Maintenance::RunJob, 2 h).
    STALE_AFTER = 30.minutes
    CONSOLE_LIMIT = 1.megabyte
    SQL_PREVIEW_LIMIT = 512.kilobytes
    TRUNCATED_MARK = "\n… (truncated)"

    belongs_to :parent_run, class_name: 'Ops::OperationRun', optional: true, inverse_of: :child_runs
    has_many :child_runs, class_name: 'Ops::OperationRun', foreign_key: :parent_run_id, inverse_of: :parent_run,
                          dependent: :nullify

    validates :operation_key, presence: true
    validates :mode, inclusion: { in: MODES }
    validates :status, inclusion: { in: STATUSES }
    validates :origin, inclusion: { in: ORIGINS }

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :previews, -> { where(mode: 'preview') }
    scope :applies, -> { where(mode: 'apply') }
    scope :pending, -> { where(status: PENDING_STATUSES) }
    scope :for_finding, ->(finding_id) { where(health_finding_id: finding_id) }

    class << self
      # +text+ cut to +limit+ bytes (valid UTF-8), with TRUNCATED_MARK when cut.
      def cap(text, limit)
        value = text.to_s
        return value if value.bytesize <= limit

        "#{value.byteslice(0, limit - TRUNCATED_MARK.bytesize).scrub('')}#{TRUNCATED_MARK}"
      end

      # SHA256 of the params (JSON with sorted keys).
      def params_digest_for(params)
        Digest::SHA256.hexdigest(JSON.generate((params || {}).to_h.stringify_keys.sort.to_h))
      end
    end

    def preview? = mode == 'preview'
    def apply? = mode == 'apply'
    def script_only? = mode == 'script_only'

    def queued? = status == 'queued'
    def running? = status == 'running'
    def pending? = PENDING_STATUSES.include?(status)
    def succeeded? = status == 'succeeded'
    def failed? = status == 'failed'
    def refused? = status == 'refused'
    def finished? = !pending?

    # True for a queued/running run that no worker will ever finish: its Solid Queue job is gone, finished or failed
    # (a worker killed mid-run), or it has been pending longer than STALE_AFTER without a known job (longer than the
    # job's concurrency duration with one). Computed on read: nothing is ever re-run or registered because of it.
    # An interrupted RUNNING apply may have changed the local DB without registering its script (see #display_status).
    def interrupted?(now: Time.current)
      return false unless pending?

      since = started_at || created_at
      case Maintenance::JobState.for(job_id)
      when :dead then true
      when :active then since < now - Maintenance::RunJob.concurrency_duration
      else since < now - STALE_AFTER
      end
    end

    # The status shown in the UI: 'interrupted' for an interrupted run, else the stored status.
    def display_status = interrupted? ? 'interrupted' : status

    # The temporary script an apply was running (kept when the worker died before the Outbox registration), or nil.
    def tmp_script_path
      path = Maintenance::Executor::TMP_DIR.join("#{id}.sql")
      path if path.file?
    end

    # Moves the row from 'queued' to 'running' with one conditional UPDATE (a duplicate perform loses).
    # Returns true when this caller took it.
    def claim!(job_id: nil, now: Time.current) # rubocop:disable Naming/PredicateMethod
      taken = self.class.where(id:, status: 'queued')
                  .update_all(status: 'running', started_at: now, job_id: job_id || self.job_id, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
      reload
      taken.positive?
    end

    # Final state (no validations: never fails on an older row).
    def finish!(status:, **attributes)
      update_columns({ status: status.to_s, finished_at: Time.current, updated_at: Time.current }.merge(attributes)) # rubocop:disable Rails/SkipsModelValidations
    end

    # Refused before running anything (+reason+: REFUSAL_REASONS); +message+ goes to error_messages.
    def refuse!(reason, message: nil, **attributes)
      messages = [message.presence || I18n.t("maintenance.refusals.#{reason}", default: reason.to_s)]
      finish!(status: 'refused', refusal_reason: reason.to_s, error_messages: messages, **attributes)
    end

    def summary_hash = (summary || {}).to_h.stringify_keys
    def warning_list = Array(warnings).map(&:to_s)
    def error_list = Array(error_messages).map(&:to_s)
    def params_hash = (params || {}).to_h.stringify_keys

    # The operation class (nil when the key is unknown).
    def operation_class
      Maintenance::Registry.find(operation_key)
    end

    # The operation built from the stored params (nil when the key is unknown).
    def operation
      operation_class&.new(params_hash.symbolize_keys.slice(*operation_class.param_names.map(&:to_sym)))
    end

    # Plan label, else the operation title.
    def display_label
      label.presence || operation_class&.title || operation_key
    end

    # Confirmation level of the dry run ('one_click', 'confirm', 'typed').
    def confirmation_level = summary_hash['confirmation'].presence || 'one_click'
    def typed_token = summary_hash['typed_token']

    def blocked? = error_list.any?
    def empty_plan? = summary_hash['empty'] == true

    # True for a succeeded dry run that can be applied (no errors, something to do).
    def appliable?
      preview? && succeeded? && sql_digest.present? && !blocked? && !empty_plan?
    end

    # The apply runs of this preview, newest first.
    def applies_of_preview = child_runs.where(mode: 'apply').order(id: :desc)

    # The latest apply run of this preview (nil when none).
    def latest_apply = applies_of_preview.first

    # True when this preview already has an apply that is pending or succeeded (one apply per preview).
    def applied_or_applying?
      applies_of_preview.exists?(status: PENDING_STATUSES + ['succeeded'])
    end

    # The registered Outbox script (nil when none).
    def sql_script
      Ops::SqlScript.find_by(id: sql_script_id) if sql_script_id
    end

    # The linked data health finding (nil when none).
    def health_finding
      Ops::HealthFinding.find_by(id: health_finding_id) if health_finding_id
    end

    # The health re-run queued after the apply (nil when none).
    def health_run
      id = summary_hash['health_run_id']
      Ops::HealthRun.find_by(id:) if id
    end

    def duration
      return unless started_at && finished_at

      finished_at - started_at
    end
  end
end
