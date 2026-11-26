# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CrawlOutput
  #
  # Checks & tidies up what a single-meeting crawl (MeetingCrawlJob) has just written for a
  # FIN event id: only files modified at/after +since+ (the crawl start) and belonging to the
  # bases DiskIndex associates with the FIN id are ever considered.
  #
  # - No fresh LT2 source for the FIN id => :failed.
  # - Meeting already linked in the DB (see DbIndex):
  #   - fresh output with results => the re-downloaded manifest PDF is moved to manifests.done
  #     (the structure is already committed); the LT2 is kept for the results review;
  #   - result-free fresh output => the fresh LT2 & the re-downloaded manifest PDF are redundant
  #     (unless the base also has an LT4 working copy or phase files): the LT2 is MOVED to the run backup folder
  #     'results.backup/<season>/cleanup-<UTC timestamp>/', the manifest PDF to manifests.done (0.10.104: nothing
  #     is deleted any more).
  # - Unlinked meeting => files are left as they are (the board then shows the next step).
  #
  # 0.10.104, shared by MeetingCrawlJob and Sources::CrawlTidy (after a Sources crawl, for each FIN id it wrote):
  # - the redundancy rule is SeasonBoard::RedundantFiles (the manifest PDF of a base having an LT4 working copy or phase
  #   files is never touched; an unparsable or PDF-derived LT2 is never redundant);
  # - the tidy-up takes ONLY the files this crawl run wrote: listed in +new_files+ (the crawl's own before/after
  #   listing, Sources::CrawlOutputs) AND modified within the run window (+since+ .. +until_time+); without
  #   +new_files+ nothing is moved;
  # - it is skipped whole when Sources::Cleanup::Safety refuses (the run: no ops DB, unreadable activity log, crawler
  #   busy, another crawl running, an apply of the clean-up page; the FIN id: a busy crawl / extraction / prepare entry
  #   or a pending run; a base: lease, pending run or commit, operator edits, review). The crawl's own activity entry
  #   (+own_key+) is not "busy";
  # - every move goes through Sources::Cleanup::Mover (no overwrite: a name already taken at the destination keeps the
  #   file in place) and is listed at once in the MOVES.txt of the run backup folder;
  # - #call never raises: a failing tidy-up leaves the crawl outcome as it is and is reported in Outcome#skipped
  #   (['FIN <id>', 'error: ...']); a failing output check answers :failed.
  #
  class CrawlOutput
    # Tolerance on the end of the run window (mtimes have whole seconds on some file systems).
    WINDOW_TOLERANCE = 1.second

    # - removed: the moved result files (their former paths); archived: the manifest files moved to manifests.done
    #   (their new paths); skipped: [path or 'FIN <id>', reason] of what was left in place (refusals, errors);
    #   backup_dir: the run backup folder relative to the data root (when used); moves: the moves listed in its MOVES.txt.
    Outcome = Data.define(:status, :message, :results, :removed, :archived, :skipped, :backup_dir, :moves) do
      def initialize(skipped: [], backup_dir: nil, moves: 0, **) = super

      # The clean-up facts for an ops event ('backup_dir', 'moves', 'skipped'), or nil when nothing moved or was kept.
      def event_data
        return nil if moves.zero? && skipped.empty?

        { 'backup_dir' => backup_dir, 'moves' => moves, 'skipped' => skipped.map { |item| item.map(&:to_s) } }
      end
    end

    # - new_files: the files the crawl run wrote (absolute paths; nil: nothing is tidied); until_time: end of the run
    #   window (default: now);
    # - own_key: the ActivityLog key of the calling crawl (MeetingCrawlJob: the FIN id; SourceCrawlJob: its 'src:' key);
    # - disk_index: a DiskIndex to reuse; safety: a Sources::Cleanup::Safety to reuse; run_folder: the
    #   Sources::Cleanup::RunFolder of the run (Sources::CrawlTidy shares them for every FIN id of a crawl).
    def initialize(season_id:, fin_event_id:, since:, data_dir: DiskIndex.default_data_dir, db_index: nil, disk_index: nil, # rubocop:disable Metrics/ParameterLists
                   new_files: nil, until_time: nil, own_key: nil, safety: nil, run_folder: nil)
      @season_id = season_id
      @fin_event_id = fin_event_id.to_s
      @since = since
      @data_dir = data_dir
      @db_index = db_index || DbIndex.new(season_id:)
      @disk_index = disk_index
      @new_files = new_files&.to_set { |path| File.expand_path(path.to_s) }
      @until_time = until_time || Time.current
      @own_key = own_key
      @safety = safety
      @run_folder = run_folder
      @outcomes = []
    end

    # Returns an Outcome (never raises).
    def call
      entry = disk_index.for(@fin_event_id)
      sources = fresh_sources(entry)
      return outcome(:failed, 'no output file found for this FIN id', false) if sources.empty?

      results = sources.any?(&:results?)
      return outcome(:done, results ? 'results found' : 'no results yet', results) unless linked?

      tidy(entry, sources, results)
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::CrawlOutput] FIN #{@fin_event_id}: output check failed: #{e.class}: #{e.message}")
      outcome(:failed, "output check failed: #{e.class}: #{e.message}".truncate(200), false)
    end

    private

    def tidy(entry, sources, results)
      reason = safety.run_refusal || safety.entry_refusal(entry)
      return outcome(:done, "#{base_message(results)} (clean-up skipped: #{reason})", results, skipped: [["FIN #{@fin_event_id}", reason]]) if reason

      owned = sources.select { |src| own_output?(src.lt2_path) }
      results ? archive_manifests(entry, owned) : remove_redundant(entry, owned)
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::CrawlOutput] FIN #{@fin_event_id}: clean-up failed: #{e.class}: #{e.message}")
      outcome(:done, "#{base_message(results)} (clean-up stopped by an error)", results,
              skipped: [["FIN #{@fin_event_id}", "error: #{e.class}: #{e.message}".truncate(200)]])
    end

    def base_message(results) = results ? 'results found' : 'no results yet'

    def disk_index
      @disk_index ||= DiskIndex.new(season_id: @season_id, data_dir: @data_dir)
    end

    def guard
      @guard ||= safety.guard
    end

    def safety
      @safety ||= Sources::Cleanup::Safety.new(season_id: @season_id, data_root: @data_dir, own_key: @own_key, crawl_slot: true)
    end

    def run_folder
      @run_folder ||= Sources::Cleanup::RunFolder.new(root: guard.root, season_id: @season_id)
    end

    def mover
      @mover ||= Sources::Cleanup::Mover.new(guard:, run_folder:)
    end

    def linked?
      @db_index.calendar_for(@fin_event_id)&.linked? || false
    end

    def fresh_sources(entry)
      return [] unless entry

      entry.sources.select { |src| fresh?(src.lt2_path) }
    end

    def fresh?(path)
      path.present? && File.exist?(path) && File.mtime(path) >= @since
    end

    # True for a file this crawl run wrote: in its own listing and modified within the run window.
    def own_output?(path)
      return false unless @new_files && fresh?(path) && @new_files.include?(File.expand_path(path.to_s))

      File.mtime(path) <= @until_time + WINDOW_TOLERANCE
    end

    # The crawl's own manifest PDFs of the given bases (never the one of a base having an LT4 working copy or phase files).
    def own_manifests(entry, sources)
      RedundantFiles.manifests_for(entry, sources.map(&:base)).select { |path| own_output?(path) }
    end

    def archive_manifests(entry, sources)
      outcomes = archive(own_manifests(entry, sources))
      outcome(:done, 'results found', true, removed: [], archived: done_targets(outcomes))
    end

    def remove_redundant(entry, sources)
      removable = sources.select { |src| RedundantFiles.removable_source?(src) }
      moves = removable.map { |src| track(mover.to_backup(src.lt2_path)) }
      archives = archive(own_manifests(entry, removable))
      removed = moves.select(&:done?).map(&:from)
      message = removed.any? ? 'no results yet (redundant crawl output moved to results.backup)' : 'no results yet'
      outcome(:done, message, false, removed:, archived: done_targets(archives))
    end

    # Archives each manifest PDF (+ '.txt') into manifests.done. Returns the Mover outcomes.
    def archive(pdf_paths)
      pdf_paths.flat_map { |path| mover.archive_manifest(path).each { |result| track(result) } }
    end

    def track(result)
      @outcomes << result
      result
    end

    def done_targets(outcomes) = outcomes.select(&:done?).map(&:to)

    def outcome(status, message, results, removed: [], archived: [], skipped: []) # rubocop:disable Metrics/ParameterLists
      skipped += @outcomes.select(&:skipped?).map { |result| [result.from, result.reason] }
      Outcome.new(status:, message:, results:, removed:, archived:, skipped:, backup_dir: @run_folder&.relative,
                  moves: @run_folder&.moves.to_i)
    end
  end
end
