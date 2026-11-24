# frozen_string_literal: true

module Ops
  #
  # = Ops::PipelineRun
  #
  # One Data-Fix pipeline run (ops DB, table 'pipeline_runs'): a build, prepare, refresh, commit or extract of a
  # subject (DiskIndex base, FIN id or PDF name), with its throttled progress (see Import::Progress::Ops), which
  # the UI reads instead of ImportStatusChannel for background work. Not rebuildable.
  #
  class PipelineRun < ApplicationRecord
    self.table_name = 'pipeline_runs'

    KINDS = %w[build prepare refresh commit extract].freeze
    ORIGINS = %w[operator auto].freeze
    STATUSES = %w[queued running done failed yielded refused].freeze
    PENDING_STATUSES = %w[queued running].freeze
    # A pending run not updated for this long is considered dead.
    STALE_AFTER = 30.minutes

    belongs_to :pipeline_source, class_name: 'Ops::PipelineSource', inverse_of: :pipeline_runs, optional: true

    validates :subject_key, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :origin, inclusion: { in: ORIGINS }
    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :pending, -> { where(status: PENDING_STATUSES) }
    scope :for_subject, ->(key) { where(subject_key: key.to_s) }

    def pending? = PENDING_STATUSES.include?(status)

    def stale?(now: Time.current)
      pending? && updated_at.present? && updated_at < now - STALE_AFTER
    end

    def record_progress!(message:, current:, total:)
      update_columns(message: message, progress: current, total: total, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    def finish!(status:, error: nil)
      update!(status: status.to_s, error: error&.to_s&.truncate(4.kilobytes), finished_at: Time.current)
    end
  end
end
