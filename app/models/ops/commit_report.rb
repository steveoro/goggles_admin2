# frozen_string_literal: true

module Ops
  #
  # = Ops::CommitReport
  #
  # One Phase 6 commit request and its outcome (ops DB, table 'commit_reports'). Created 'queued' only by
  # DataFix::CommitsController#commit_phase6 (an operator click), performed by DataFixCommitJob through
  # DataFix::CommitRunner, shown by DataFix::CommitReportsController#show (reopenable by id).
  #
  # == Attributes
  # - pipeline_source_id (optional), season_id, source_base, source_path (path committed, results.new);
  # - status (STATUSES): queued -> running -> committed | committed_archive_failed | failed; refused when the
  #   job refused to start (not queued any more, no requesting user, guards or preflight);
  # - requested_by_user_id, requested_at, started_at, finished_at, job_id;
  # - preflight (the POST-time preflight, incl. 'drift_ack' / 'create_anyway'), summary (counts shown on the
  #   commit summary), stats (Import::Committers::Main#stats), error_message, archive_error, first_error_phase;
  # - log_rel_path, sql_rel_path (relative to the crawler data root), sql_script_id (Ops::SqlScript), done_dir,
  #   meeting_id; health_run_ids ({ group => Ops::HealthRun id }), post_commit_checks (legacy JSON report);
  # - db_generation_after; progress_message / progress_current / progress_total (throttled, see Import::Progress::Ops).
  #
  class CommitReport < ApplicationRecord
    self.table_name = 'commit_reports'

    STATUSES = %w[queued running committed committed_archive_failed failed refused].freeze
    PENDING_STATUSES = %w[queued running].freeze
    COMMITTED_STATUSES = %w[committed committed_archive_failed].freeze
    # Rows of the statistics table of the report: [label, created stat key, updated stat key or nil].
    STAT_GROUPS = [
      ['Cities', :cities_created, :cities_updated], ['Swimming Pools', :pools_created, :pools_updated],
      ['Meetings', :meetings_created, :meetings_updated], ['Calendars', :calendars_created, :calendars_updated],
      ['Sessions', :sessions_created, :sessions_updated], ['Teams', :teams_created, :teams_updated],
      ['Affiliations', :affiliations_created, nil], ['Swimmers', :swimmers_created, :swimmers_updated],
      ['Badges', :badges_created, nil], ['Events', :events_created, :events_updated],
      ['Programs', :programs_created, :programs_updated], ['Individual Results', :mirs_created, :mirs_updated],
      ['Individual Results Deleted', :mirs_deleted, nil], ['Laps', :laps_created, :laps_updated],
      ['Laps Deleted', :laps_deleted, nil], ['Relay Results', :mrrs_created, :mrrs_updated],
      ['Relay Swimmers', :mrss_created, :mrss_updated], ['Relay Laps', :relay_laps_created, :relay_laps_updated],
      ['Team Scores', :team_scores_created, :team_scores_updated]
    ].freeze
    # Step label of the first logged error (by phase), see #first_error_step_label.
    STEP_KEYS = { 1 => 'sessions', 2 => 'teams', 3 => 'swimmers', 4 => 'events', 5 => 'results' }.freeze

    belongs_to :pipeline_source, class_name: 'Ops::PipelineSource', inverse_of: :commit_reports, optional: true

    validates :status, inclusion: { in: STATUSES }
    validates :source_base, :requested_by_user_id, :requested_at, presence: true

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :pending, -> { where(status: PENDING_STATUSES) }
    scope :for_base, ->(base) { where(source_base: base.to_s) }

    def queued? = status == 'queued'
    def running? = status == 'running'
    def pending? = PENDING_STATUSES.include?(status)
    def committed? = COMMITTED_STATUSES.include?(status)
    def failed? = status == 'failed'
    def refused? = status == 'refused'
    def archive_failed? = status == 'committed_archive_failed'
    def finished? = !pending?

    # Moves the row from 'queued' to 'running' with one conditional UPDATE (a duplicate perform loses).
    # Returns true when this caller took it.
    def claim!(job_id: nil, now: Time.current) # rubocop:disable Naming/PredicateMethod
      taken = self.class.where(id:, status: 'queued')
                  .update_all(status: 'running', started_at: now, job_id: job_id || self.job_id, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
      reload
      taken.positive?
    end

    # Throttled progress write (see Import::Progress::Ops): no validations, no callbacks.
    def record_progress!(message:, current:, total:)
      update_columns(progress_message: message, progress_current: current, progress_total: total, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Final state; never raises on a validation problem of older rows.
    def finish!(status:, **attributes)
      update_columns({ status: status.to_s, finished_at: Time.current, updated_at: Time.current }.merge(attributes)) # rubocop:disable Rails/SkipsModelValidations
    end

    def refuse!(message)
      finish!(status: 'refused', error_message: message.to_s.truncate(4.kilobytes))
    end

    # The registered Outbox script of the commit, or nil.
    def sql_script
      Ops::SqlScript.find_by(id: sql_script_id) if sql_script_id
    end

    def sql_filename
      File.basename(sql_rel_path) if sql_rel_path.present?
    end

    def log_filename
      File.basename(log_rel_path) if log_rel_path.present?
    end

    # i18n key suffix of the step to review first (data_fix.steps.<key>), or nil.
    def first_error_step_key
      STEP_KEYS[first_error_phase.to_i]
    end

    # Stats with symbol keys (as Import::Committers::Main returns them).
    def stats_hash
      (stats || {}).to_h.deep_symbolize_keys
    end

    # Non-empty rows of the statistics table: [label, created, updated ('-' when not tracked)], plus the totals.
    def self.stat_rows(stats) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      rows = STAT_GROUPS.filter_map do |label, created_key, updated_key|
        created = stats[created_key].to_i
        updated = updated_key ? stats[updated_key].to_i : '-'
        [label, created, updated] unless created.zero? && (updated == '-' || updated.zero?)
      end
      totals = [STAT_GROUPS.sum { |_label, key, _updated| stats[key].to_i },
                STAT_GROUPS.sum { |_label, _created, key| key ? stats[key].to_i : 0 }]
      [rows, totals]
    end

    def percent_done
      return nil unless progress_total.to_i.positive?

      ((progress_current.to_f / progress_total) * 100).clamp(0, 100).round
    end
  end
end
