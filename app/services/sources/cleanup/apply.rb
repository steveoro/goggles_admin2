# frozen_string_literal: true

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::Apply
    #
    # Applies the clean-up of one season the operator reviewed on the clean-up page (0.10.104; an operator click only,
    # Sources::CleanupsController#create):
    #
    # 1. refuses without the ops DB, and while another apply of the season runs (Sources::Cleanup::ApplyLock, held for
    #    the whole run and always released; :apply_running);
    # 2. plans again (Sources::Cleanup::Plan) and refuses when the run is blocked (crawler busy, a crawl queued or
    #    running, unreadable activity log), when the digest differs from the one the operator saw (anything changed
    #    meanwhile), or when nothing is left to move;
    # 3. performs the moves one by one with Sources::Cleanup::Mover (no overwrite, no delete): result files into the run
    #    backup folder 'results.backup/<season>/cleanup-<UTC timestamp>[-N]/' (Sources::Cleanup::RunFolder, reserved
    #    atomically), manifests (+ '.txt') into manifests.done, calendar files into calendar.done. Right before EACH item
    #    the Safety checks are read again (the run, the FIN id, the base, the file): a refused item is skipped and
    #    reported; a file skipped by the Mover (a name taken meanwhile) is reported; the first unexpected error STOPS the
    #    run (the files not reached stay where they are). Each completed move is listed at once in the MOVES.txt of the
    #    run backup folder (the undo record, also when the run is killed half way);
    # 4. records the ops event 'sources.cleanup_applied' (counts, backup folder, error) and refreshes the Season board
    #    (SeasonBoard::Snapshot.invalidate!, SeasonBoard::Notifier.ping), so its "redundant file" / "PDF pending" flags
    #    go away at once.
    #
    # No DB write, no commit, no push.
    #
    class Apply
      EVENT_KIND = 'sources.cleanup_applied'
      # Moves listed in the event data (all of them are in the MOVES.txt of the backup folder).
      EVENT_MOVES_LIMIT = 100

      # - status: :done | :failed (stopped by an error) | :refused (nothing done; +reason+ says why);
      # - outcomes: the Mover outcomes (a refused item: a skipped outcome with the Safety reason); error: the message
      #   of the error that stopped the run; backup_dir: relative.
      Result = Data.define(:status, :reason, :outcomes, :error, :backup_dir) do
        def done? = status == :done
        def refused? = status == :refused
        def moved = outcomes.select(&:done?)
        def skipped = outcomes.select(&:skipped?)
      end

      attr_reader :season_id

      # - digest: the Plan#digest the operator saw; plan: a Plan to use (default: a new one);
      # - safety_options: extra Sources::Cleanup::Safety options of the per-item checks (specs: crawler_status).
      def initialize(season_id:, digest:, data_root: Sources.data_root, now: Time.current, plan: nil, safety_options: {}) # rubocop:disable Metrics/ParameterLists
        @season_id = season_id.to_i
        @digest = digest.to_s
        @data_root = Pathname.new(data_root)
        @now = now
        @plan = plan
        @safety_options = safety_options
      end

      def call
        return refused(:ops_unavailable) unless Ops.safely(false) { Ops.available? }

        result = nil
        locked = ApplyLock.new(season_id).synchronize { result = checked_run }
        locked ? result : refused(:apply_running)
      end

      private

      def checked_run
        plan = @plan || Plan.new(season_id:, data_root: @data_root, now: @now, safety: new_safety(now: @now))
        return refused(plan.blocked_reason) if plan.blocked_reason
        return refused(:digest_mismatch) unless ActiveSupport::SecurityUtils.secure_compare(plan.digest, @digest)
        return refused(:nothing_to_move) if plan.move_items.empty?

        run(plan)
      end

      def new_safety(now: Time.current)
        Safety.new(season_id:, data_root: @data_root, now:, holds_apply_lock: true, **@safety_options)
      end

      def run(plan)
        @guard = plan.guard
        @run_folder = RunFolder.new(root: @guard.root, season_id:, now: @now)
        @mover = Mover.new(guard: @guard, run_folder: @run_folder)
        outcomes = []
        error = nil
        plan.move_items.each do |item|
          outcomes.concat(perform(item))
        rescue StandardError => e
          error = "#{item.relative}: #{e.class}: #{e.message}".truncate(300)
          Rails.logger.error("[Sources::Cleanup::Apply] season #{season_id}: stopped at #{error}")
          break
        end
        finish(outcomes, error)
      end

      # The item's moves, or a skipped outcome when the Safety checks, read again now, refuse it.
      def perform(item)
        reason = item_refusal(item)
        return [Mover::Outcome.new(status: :skipped, from: item.path, to: nil, reason:)] if reason

        case item.rule
        when :result_free_source then [@mover.to_backup(item.path)]
        when :pending_manifest then @mover.archive_manifest(item.path)
        else [@mover.call(item.path, dir: @data_root.join('calendar.done', season_id.to_s), duplicate_origin: 'calendar.new')]
        end
      end

      def item_refusal(item)
        safety = new_safety
        base = item_base(item)
        safety.run_refusal || safety.fin_refusal(item.fin_event_id) || (base && safety.base_refusal(base)) || safety.file_refusal(item.path)
      end

      def item_base(item)
        case item.rule
        when :result_free_source then Ops::PipelineSource.base_for(item.path)
        when :pending_manifest then SeasonBoard::RedundantFiles.manifest_base(item.path)
        end
      end

      def finish(outcomes, error)
        backup = @run_folder.relative
        record_event(outcomes, error, backup)
        refresh_board
        Result.new(status: error ? :failed : :done, reason: nil, outcomes:, error:, backup_dir: backup)
      end

      def record_event(outcomes, error, backup)
        moved = outcomes.select(&:done?)
        Ops.record_event!(
          kind: EVENT_KIND, level: error ? 'error' : 'success', actor: 'operator', season_id:,
          subject_type: 'source_cleanup', subject_key: backup || "season-#{season_id}",
          data: event_counts(moved, outcomes).merge(
            'backup_dir' => backup, 'error' => error,
            'moves' => moved.first(EVENT_MOVES_LIMIT).map { |outcome| [@guard.relative(outcome.from), @guard.relative(outcome.to)] }
          ),
          link_path: Rails.application.routes.url_helpers.sources_cleanup_path(season_id:)
        )
      end

      def event_counts(moved, outcomes)
        tally = moved.select(&:moved?).map { |outcome| destination_kind(outcome) }.tally
        { 'moved' => tally.fetch(:backup, 0), 'archived' => tally.fetch(:manifests, 0), 'calendar' => tally.fetch(:calendar, 0),
          'duplicates' => moved.count(&:duplicate?), 'skipped' => outcomes.count(&:skipped?) }
      end

      # :backup, :manifests or :calendar: where a moved file went.
      def destination_kind(outcome)
        target = outcome.to.to_s
        return :backup if @run_folder.reserved? && target.start_with?("#{@run_folder.path}/")

        target.include?('/manifests.done/') ? :manifests : :calendar
      end

      def refresh_board
        SeasonBoard::Snapshot.invalidate!(season_id)
        SeasonBoard::Notifier.ping
      rescue StandardError => e
        Rails.logger.warn("[Sources::Cleanup::Apply] board refresh failed: #{e.class}: #{e.message}")
      end

      def refused(reason)
        Result.new(status: :refused, reason:, outcomes: [], error: nil, backup_dir: nil)
      end
    end
  end
end
