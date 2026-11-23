# frozen_string_literal: true

module Ops
  #
  # = Ops::PushRun
  #
  # One Outbox push run (ops DB, table 'push_runs'): created by OutboxController#push after the operator's
  # confirmation, performed by Outbox::PushJob (Outbox::Pusher), never started by anything else.
  #
  # == Attributes
  # - user_id: the operator who clicked (their users.jwt is read at run time); target_api_url, target_env;
  # - script_ids: Ops::SqlScript ids, pushed in seq order; override_order: lower pending scripts don't block;
  # - status (STATUSES): running, finished (all pushed), stopped (first error), aborted (nothing posted:
  #   target unreachable, expired JWT, job failure); pushed_count, stopped_at_script_id, error;
  # - job_id, started_at, finished_at.
  #
  class PushRun < ApplicationRecord
    self.table_name = 'push_runs'

    STATUSES = %w[running finished stopped aborted].freeze
    # A running run not updated for this long is considered dead (see #live?).
    LIVE_FOR = Ops::SqlScript::STALE_PUSHING_AFTER

    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(started_at: :desc, id: :desc) }
    scope :running, -> { where(status: 'running') }

    # True when a running run was updated recently (see LIVE_FOR).
    def self.live?(now: Time.current)
      running.where(arel_table[:updated_at].gteq(now - LIVE_FOR)).exists?
    end

    def running? = status == 'running'
    def finished? = status == 'finished'
    def stopped? = status == 'stopped'
    def aborted? = status == 'aborted'

    def live?(now: Time.current)
      running? && updated_at.present? && updated_at >= now - LIVE_FOR
    end

    # The scripts of the run, in seq order.
    def scripts
      Ops::SqlScript.where(id: Array(script_ids)).ordered
    end

    def total
      Array(script_ids).size
    end

    def finish!
      update!(status: 'finished', finished_at: Time.current)
    end

    def stop!(script:, error:)
      update!(status: 'stopped', stopped_at_script_id: script&.id, error: error.to_s.truncate(4.kilobytes),
              finished_at: Time.current)
    end

    def abort!(error)
      update!(status: 'aborted', error: error.to_s.truncate(4.kilobytes), finished_at: Time.current)
    end

    def status_label
      I18n.t("outbox.runs.statuses.#{status}", default: status.humanize)
    end
  end
end
