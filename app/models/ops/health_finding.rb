# frozen_string_literal: true

module Ops
  #
  # = Ops::HealthFinding
  #
  # One data health issue of a season (ops DB, table 'health_findings'), kept in sync by Health::FindingSync
  # after each successful group run; the operator's triage (status, note) survives the next runs because the
  # row is keyed by (season_id, check_key, fingerprint).
  #
  # == Attributes
  # - season_id, group_key (Ops::HealthRun::GROUPS), check_key (Health::Registry key), fingerprint (see .fingerprint_for);
  # - severity (SEVERITIES), status (STATUSES);
  # - subject_type ('meeting', 'calendar', 'swimmer', 'badge', 'teams', 'swimmers', 'season', ...), subject_id
  #   (main entity id), subject_ids (sorted ids, comma-separated, for multi-entity subjects);
  # - title (interpolated at sync), payload (evidence Hash), payload_digest (SHA256 of the payload);
  # - note, status_changed_at, status_changed_by (user id);
  # - first_seen_run_id, last_seen_run_id, first_seen_at, last_seen_at, resolved_at.
  #
  class HealthFinding < ApplicationRecord
    self.table_name = 'health_findings'

    SEVERITIES = %w[error warning info].freeze
    STATUSES = %w[open acknowledged ignored resolved].freeze
    # Statuses shown by default (resolved ones are hidden).
    VISIBLE_STATUSES = %w[open acknowledged ignored].freeze
    # Resolved findings are deleted this long after their resolved_at (see .prune_resolved!).
    RESOLVED_RETENTION = 180.days

    validates :season_id, :check_key, :fingerprint, presence: true
    validates :group_key, inclusion: { in: Ops::HealthRun::GROUPS }
    validates :severity, inclusion: { in: SEVERITIES }
    validates :status, inclusion: { in: STATUSES }

    scope :for_season, ->(season_id) { where(season_id:) }
    scope :for_group, ->(group_key) { where(group_key: group_key.to_s) }
    scope :for_check, ->(check_key) { where(check_key: check_key.to_s) }
    scope :visible, -> { where(status: VISIBLE_STATUSES) }
    scope :open_status, -> { where(status: 'open') }
    scope :unresolved, -> { where(status: %w[open acknowledged]) }
    scope :errors, -> { where(severity: 'error') }
    scope :warnings, -> { where(severity: 'warning') }
    # Errors first, then warnings, then infos; newest first inside a severity.
    scope :by_severity, lambda {
      order(Arel.sql("CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END"), last_seen_at: :desc, id: :desc)
    }

    class << self
      # SHA256 hex of "<check_key>|<season_id>|<identity>". The identity uses entity ids only
      # (e.g. 'meeting:19412', 'swimmer:123|badges:45,67'): never names, counts or dates.
      def fingerprint_for(check_key:, season_id:, identity:)
        Digest::SHA256.hexdigest("#{check_key}|#{season_id}|#{identity}")
      end

      # SHA256 hex of a payload (JSON with sorted keys, so that the key order never matters).
      def digest_for(payload)
        Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload.as_json)))
      end

      # Deletes the resolved findings older than RESOLVED_RETENTION. Returns the deleted count.
      def prune_resolved!(now: Time.current)
        where(status: 'resolved').where(resolved_at: ...(now - RESOLVED_RETENTION)).delete_all
      end

      private

      def deep_sort(value)
        case value
        when Hash then value.keys.sort.index_with { |key| deep_sort(value[key]) }
        when Array then value.map { |item| deep_sort(item) }
        else value
        end
      end
    end

    def open? = status == 'open'
    def acknowledged? = status == 'acknowledged'
    def ignored? = status == 'ignored'
    def resolved? = status == 'resolved'

    # Sorted Integer ids of a multi-entity subject (empty when none).
    def subject_id_list
      subject_ids.to_s.split(',').map(&:to_i)
    end

    # The Health::Registry check definition (nil for an unknown key).
    def check
      Health::Registry.find(check_key)
    end

    # Title in the current locale, from the payload title args; falls back to the stored title (e.g. a row stored by an
    # older check version whose text takes other arguments, until its next run).
    def display_title
      args = payload.is_a?(Hash) ? payload.fetch('title_args', {}).to_h.symbolize_keys : {}
      key = payload.is_a?(Hash) ? payload.fetch('title_key', 'finding') : 'finding'
      I18n.t("health.checks.#{check_key}.#{key}", **args, default: title.presence || check_key)
    rescue I18n::MissingInterpolationArgument
      title.presence || check_key
    end

    # The copyable command with the ids filled in (nil when the check has none).
    def rake_command
      check&.rake_command(payload.is_a?(Hash) ? payload.fetch('rake', {}) : {})
    end

    # True when the finding was last seen before the current DB epoch (the local DB was restored since).
    def stale?(db_epoch: Ops::Setting.db_epoch, run_epochs: {})
      epoch = run_epochs.fetch(last_seen_run_id) { Ops::HealthRun.where(id: last_seen_run_id).pick(:db_epoch) }
      epoch.present? && epoch.to_i < db_epoch.to_i
    end
  end
end
