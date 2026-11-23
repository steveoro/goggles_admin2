# frozen_string_literal: true

module Ops
  #
  # = Ops::PipelineSource
  #
  # One Data-Fix source (ops DB, table 'pipeline_sources'), keyed by (season_id, base): +base+ is the
  # SeasonBoard::DiskIndex base name (file name without '.json' and '-lt4'), stable from results.new to
  # results.done. Written by DataFix::Pipeline (stage, review summary, lease); rebuildable from disk.
  #
  # == Attributes
  # - season_id, base, fin_event_id, source_kind (SOURCE_KINDS), source_path, source_sha256;
  # - stage (STAGES) + stage_reason (e.g. 'source_changed_under_edits') + stage_details (e.g. the kept phases),
  #   review_phase, review_count,
  #   new_teams_count, new_swimmers_count, db_generation (the data_fix.db_generation of the last summary);
  # - lease_owner, lease_expires_at: the build lease (see #acquire_lease!);
  # - prepared_at, committed_at.
  #
  class PipelineSource < ApplicationRecord
    self.table_name = 'pipeline_sources'

    STAGES = %w[new preparing needs_review blocked ready_to_commit committing committed failed].freeze
    SOURCE_KINDS = %w[results manifest result_free].freeze
    # Stage reason set by DataFix::Pipeline#invalidate! when it refused to delete edited phases.
    SOURCE_CHANGED_UNDER_EDITS = 'source_changed_under_edits'
    LEASE_TTL = 10.minutes

    has_many :phase_verdicts, class_name: 'Ops::PhaseVerdict', inverse_of: :pipeline_source, dependent: :delete_all
    has_many :commit_reports, class_name: 'Ops::CommitReport', inverse_of: :pipeline_source, dependent: :nullify
    has_many :pipeline_runs, class_name: 'Ops::PipelineRun', inverse_of: :pipeline_source, dependent: :nullify

    validates :season_id, :base, presence: true
    validates :stage, inclusion: { in: STAGES }
    validates :source_kind, inclusion: { in: SOURCE_KINDS }, allow_nil: true

    # DiskIndex base name of a source (or phase) path: 'x/262/foo-lt4.json' => 'foo'.
    def self.base_for(path)
      File.basename(path.to_s, '.json').sub(/-phase\d+\z/, '').delete_suffix('-lt4')
    end

    # Season id from the folder name of the path (0 when the folder is not numeric, e.g. spec temp dirs).
    def self.season_id_for(path)
      Integer(File.basename(File.dirname(path.to_s)), exception: false) || 0
    end

    # Finds or creates the row of the source at +path+ (keeps +source_path+ current).
    def self.for_path!(path, season_id: nil)
      key = { season_id: season_id || season_id_for(path), base: base_for(path) }
      row = find_or_create_by!(key) { |source| source.source_path = path.to_s }
      row.update_column(:source_path, path.to_s) if row.source_path != path.to_s # rubocop:disable Rails/SkipsModelValidations
      row
    rescue ActiveRecord::RecordNotUnique
      find_by!(key)
    end

    # Takes the build lease for +owner+ with one conditional UPDATE (atomic under SQLite): succeeds when the
    # lease is free, expired or already held by +owner+. Returns true when taken.
    def acquire_lease!(owner, ttl: LEASE_TTL, now: Time.current) # rubocop:disable Naming/PredicateMethod
      taken = self.class.where(id:)
                  .where('lease_owner IS NULL OR lease_owner = ? OR lease_expires_at IS NULL OR lease_expires_at < ?', owner, now)
                  .update_all(lease_owner: owner, lease_expires_at: now + ttl, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
      reload if taken.positive?
      taken.positive?
    end

    # Releases the lease when held by +owner+. Returns true when released.
    def release_lease!(owner) # rubocop:disable Naming/PredicateMethod
      released = self.class.where(id:, lease_owner: owner)
                     .update_all(lease_owner: nil, lease_expires_at: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      reload if released.positive?
      released.positive?
    end

    # True when someone else holds a lease that has not expired.
    def leased_by_other?(owner, now: Time.current)
      lease_owner.present? && lease_owner != owner && lease_expires_at.present? && lease_expires_at > now
    end

    def source_changed_under_edits?
      stage == 'blocked' && stage_reason == SOURCE_CHANGED_UNDER_EDITS
    end

    def verdict_for(phase)
      phase_verdicts.find { |verdict| verdict.phase == phase.to_i }
    end
  end
end
