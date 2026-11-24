# frozen_string_literal: true

require 'digest'

module SeasonBoard
  #
  # = SeasonBoard::PipelineIndex
  #
  # Pipeline facts of the Data-Fix sources of one season (phase 10), read from the ops DB with three small queries per
  # board build (pipeline_sources of the season, their phase_verdicts, the latest 'prepare' pipeline_runs row of each)
  # and reconciled with the files found by DiskIndex: a row is looked up by the base of the entry's active source
  # (review source, else results / structure / result-free source). A row without files is never reported (its stored
  # stage is left alone); files without a row get no facts, so the board keeps today's states (a pre-09 phase file
  # is adopted as edited and stays :in_review).
  #
  # Without the ops DB every lookup answers nil. A failed ops read is contained (the board falls back to the former
  # states) but recorded: #read_error? tells the planner not to trust the facts of this build (fail closed).
  #
  # == Facts (see Facts below)
  # - stage / review_phase / review_count / new_teams / new_swimmers: the stored Ops::PipelineSource summary;
  # - verdicts?: verdict rows exist; fresh?: all five verdicts were computed after the newest file of the source and
  #   under the current data_fix.db_generation (or no new entity depends on it);
  # - preparing?: a prepare job holds the lease, or a prepare run is queued/running (not stale);
  # - held?: the operator held the row (pipeline_sources.auto_prepare false);
  # - edited_recorded?: a verdict row records operator edits / an adopted file (the planner re-checks the files);
  # - stale_phases: phases whose stored verdict is 'stale'; db_behind?: new entities and a newer db generation;
  # - collision_bases: the other sources named by a phase 5 'collisions' issue;
  # - last_run: the latest prepare Ops::PipelineRun (or nil); prepare_failed?: the last prepare failed (or the stage is
  #   'failed') and the source did not change since.
  #
  class PipelineIndex # rubocop:disable Metrics/ClassLength
    # Tolerance between a verdict's checked_at and the file mtimes.
    FRESH_TOLERANCE = 1.second
    STAGES_IN_REVIEW = %w[needs_review blocked].freeze

    Facts = Data.define(
      :source_id, :base, :source_path, :stage, :stage_reason, :review_phase, :review_count, :new_teams, :new_swimmers, :held,
      :preparing, :verdict_count, :fresh, :edited_recorded, :stale_phases, :db_behind, :collision_bases, :last_run,
      :failed, :source_changed, :failed_phase, :failed_message, :highest_phase
    ) do
      def held? = held
      def preparing? = preparing
      def verdicts? = verdict_count.positive?
      def fresh? = fresh
      def edited_recorded? = edited_recorded
      def db_behind? = db_behind

      # Last prepare failed (or the stage is 'failed') and the source is unchanged since.
      def prepare_failed? = failed && !source_changed && !preparing

      # The source failed, but its file changed since (the planner may prepare it again).
      def failed_but_changed? = failed && source_changed

      # Every verdict clean and fresh.
      def ready_to_commit? = !preparing && stage == 'ready_to_commit' && fresh

      # A phase needs a decision (review / blocked), or a stored "ready" is no longer current.
      def needs_review?
        return false if preparing || !verdicts?

        STAGES_IN_REVIEW.include?(stage) || (stage == 'ready_to_commit' && !fresh)
      end

      def blocked? = stage == 'blocked'

      # Step to resume at for :needs_review.
      def review_step = review_phase || highest_phase || 1
    end

    attr_reader :season_id

    # == Params
    # - season_id: board season id;
    # - generation: current data_fix.db_generation (default: DataFix::Pipeline.db_generation, read once).
    def initialize(season_id:, generation: nil)
      @season_id = season_id.to_i
      @generation = generation
    end

    # Facts for a DiskIndex::Entry (nil when its active source has no ops row, or without the ops DB).
    def for_entry(entry)
      source = active_source(entry)
      return nil unless source

      row = rows_by_base[source.base]
      row && build_facts(row, source)
    end

    # The source the facts are about: the one in review, else the newest results / structure / result-free one.
    def self.active_source(entry)
      return nil unless entry

      entry.review_source || entry.results_source || entry.structure_source || entry.result_free_source
    end

    delegate :active_source, to: :class

    # Stored rows of the season (Hash base => Ops::PipelineSource), loaded once.
    def rows_by_base
      @rows_by_base ||= read({}) do
        next {} unless Ops.available?

        Ops::PipelineSource.where(season_id: @season_id).index_by(&:base)
      end
    end

    def generation
      @generation ||= DataFix::Pipeline.db_generation
    end

    # True when an ops query of this index failed (its facts are incomplete: automatic work must not rely on them).
    def read_error? = @read_error == true

    private

    def build_facts(row, source) # rubocop:disable Metrics/AbcSize
      verdicts = verdicts_by_source.fetch(row.id, [])
      run = last_runs.fetch(row.id, nil)
      failed = failed?(row, run, verdicts)
      Facts.new(
        source_id: row.id, base: row.base, source_path: row.source_path, stage: row.stage, stage_reason: row.stage_reason,
        review_phase: row.review_phase, review_count: row.review_count.to_i, new_teams: row.new_teams_count.to_i,
        new_swimmers: row.new_swimmers_count.to_i, held: row.held?, preparing: preparing?(row, run),
        verdict_count: verdicts.size, fresh: fresh?(row, verdicts, source), edited_recorded: edited_recorded?(verdicts),
        stale_phases: verdicts.select { |verdict| verdict.status == 'stale' }.map(&:phase).sort,
        db_behind: db_behind?(row), collision_bases: collision_bases(verdicts), last_run: run,
        failed:, source_changed: failed && source_changed?(row, run, source), failed_phase: failed_phase(run, verdicts),
        failed_message: failed_message(run, verdicts), highest_phase: source.phase
      )
    end

    # == Queries (once per index)

    def verdicts_by_source
      @verdicts_by_source ||= read({}) do
        ids = rows_by_base.values.map(&:id)
        ids.empty? ? {} : Ops::PhaseVerdict.where(pipeline_source_id: ids).to_a.group_by(&:pipeline_source_id)
      end
    end

    def last_runs
      @last_runs ||= read({}) do
        ids = rows_by_base.values.map(&:id)
        next {} if ids.empty?

        latest = Ops::PipelineRun.where(pipeline_source_id: ids, kind: 'prepare').group(:pipeline_source_id).select('MAX(id)')
        Ops::PipelineRun.where(id: latest).index_by(&:pipeline_source_id)
      end
    end

    # Runs an ops read, returning +default+ (and flagging #read_error?) when it raises.
    def read(default)
      yield
    rescue StandardError => e
      @read_error = true
      Rails.logger.warn("[SeasonBoard::PipelineIndex] ops read failed: #{e.class}: #{e.message}")
      default
    end

    # == Facts helpers

    def preparing?(row, run)
      row.leased_by_job? || (run.present? && run.pending? && !run.stale?)
    end

    # Five verdicts computed after the newest file of the source, under the current generation (when it matters).
    def fresh?(row, verdicts, source)
      return false if verdicts.size < DataFix::Pipeline::PHASES.size

      checked_at = verdicts.filter_map(&:checked_at).min
      return false if checked_at.nil? || (source.mtime && checked_at < source.mtime - FRESH_TOLERANCE)

      !db_behind?(row)
    end

    def db_behind?(row)
      row.db_generation.to_i < generation && (row.new_teams_count.to_i + row.new_swimmers_count.to_i).positive?
    end

    def edited_recorded?(verdicts)
      verdicts.any? do |verdict|
        counts = verdict.counts.to_h
        verdict.operator_edited_at.present? || counts['_edited'] == true || counts['_adopted'] == true
      end
    end

    def collision_bases(verdicts)
      verdict = verdicts.find { |row| row.phase == 5 && row.status == 'blocked' }
      issue = verdict && Array(verdict.issues).find { |row| row['code'] == 'collisions' }
      Array(issue && issue['details']).map { |name| Ops::PipelineSource.base_for(name) }.uniq
    end

    # The last prepare failed (and no build or verdict came after it), or the stored stage is 'failed'.
    def failed?(row, run, verdicts)
      return true if row.stage == 'failed'
      return false unless run&.status == 'failed'

      latest = verdicts.filter_map(&:checked_at).max
      latest.nil? || run.finished_at.nil? || latest <= run.finished_at + FRESH_TOLERANCE
    end

    # The source changed since the failure: its SHA256 differs from the one stored at the failure, or the LT2 / LT4
    # file is newer than the failed run.
    def source_changed?(row, run, source)
      newer_than?(source, run&.finished_at) || sha_changed?(row)
    end

    # The LT2 / LT4 file of the source is newer than +time+.
    def newer_than?(source, time)
      time.present? && [source.lt2_path, source.lt4_path].compact.any? { |path| mtime(path)&.>(time) }
    end

    # The stored source SHA256 of the failure differs from the current one.
    def sha_changed?(row)
      return false if row.failed_source_sha256.blank? || row.source_path.blank? || !File.exist?(row.source_path)

      Digest::SHA256.file(row.source_path).hexdigest != row.failed_source_sha256
    rescue SystemCallError
      false
    end

    def failed_phase(run, verdicts)
      run&.phase || verdicts.select { |verdict| verdict.status == 'failed' }.map(&:phase).min
    end

    def failed_message(run, verdicts)
      return run.error.to_s.truncate(200) if run&.status == 'failed' && run.error.present?

      verdict = verdicts.find { |row| row.status == 'failed' }
      verdict&.counts.to_h['_message'].to_s.truncate(200).presence
    end

    def mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end
  end
end
