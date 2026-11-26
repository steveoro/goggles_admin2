# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlTidy
  #
  # Automatic tidy-up at the end of a SourceCrawlJob that ended 'done' (0.10.104). It applies ONLY the rules of the
  # board's own crawl tidy-up, never the wider ones of the clean-up page, and only to the files this crawl run wrote
  # (+new_files+, the job's before/after listing, modified within the run window):
  #
  # - kinds 'calendar_results' and 'fin_meeting': for each FIN event id of the LT2 files the crawl wrote in
  #   'results.new/<season>', SeasonBoard::CrawlOutput (the MeetingCrawlJob rule: linked meeting, no LT4 working copy,
  #   no phase files, a readable crawl LT2): a result-free LT2 moves to the run backup folder
  #   'results.backup/<season>/cleanup-<UTC timestamp>/', its manifest PDF (or the one of a crawl with results) to
  #   manifests.done. CrawlOutput skips a FIN id with a busy crawl / extraction / prepare entry or pending run, or a base
  #   that is leased, has a pending run or commit, records operator edits or is in review (Cleanup::Safety);
  # - kinds 'calendar' and 'calendar_results': Sources::CalendarTidy (superseded originals, finished '-sel-' subsets
  #   and '-skip' leftovers older than 10 minutes => calendar.done).
  #
  # Nothing runs when the ops DB or the activity log can't be read, the crawler status is busy, an apply of the
  # clean-up page holds the season, or another crawl is RUNNING (a queued one cannot start before this job ends: same
  # concurrency slot); the caller's own entry (+own_key+) aside: "not busy" must be proven. Every move is listed at
  # once in the MOVES.txt of the run backup folder (Sources::Cleanup::RunFolder).
  #
  # ::after_crawl is the SourceCrawlJob hook: it never raises and returns the job's end message with the summary of
  # the tidy-up appended (so the finish event, the activity entry and the toast carry it); the job then refreshes the
  # board as after every crawl (Snapshot.invalidate!, Notifier.ping). No commit, push or DB write here.
  #
  class CrawlTidy
    RESULT_KINDS = %w[calendar_results fin_meeting].freeze
    CALENDAR_KINDS = %w[calendar calendar_results].freeze

    # - moved: result files moved to the backup folder (former paths); archived: manifest files moved to
    #   manifests.done; calendar: calendar files moved to calendar.done; skipped: [path or 'FIN <id>', reason];
    #   refused: the reason refusing the whole run (or nil); backup_dir: the run backup folder when used.
    Report = Data.define(:moved, :archived, :calendar, :skipped, :refused, :backup_dir, :moves) do
      def self.empty(refused: nil) = new(moved: [], archived: [], calendar: [], skipped: [], refused:, backup_dir: nil, moves: 0)

      def any? = moved.any? || archived.any? || calendar.any? || skipped.any? || refused.present?
    end

    # The SourceCrawlJob hook (see the class notes): returns +message+ with the summary appended. Never raises.
    def self.after_crawl(request, new_files:, since:, data_root:, own_key:, message:, on_report: nil) # rubocop:disable Metrics/ParameterLists
      report = new(kind: request.kind, season_id: request.season_id, new_files:, since:, data_root:, own_key:).call
      on_report&.call(report)
      Rails.logger.info("[Sources::CrawlTidy] #{own_key}: moved #{report.moved.size}, archived #{report.archived.size}, calendar " \
                        "#{report.calendar.size}, skipped #{report.skipped.inspect}, refused #{report.refused.inspect}")
      report.any? ? [message, summary(report)].compact_blank.join(' ') : message
    rescue StandardError => e
      Rails.logger.warn("[Sources::CrawlTidy] #{own_key}: clean-up skipped: #{e.class}: #{e.message}")
      message
    end

    # One-line summary of a Report (i18n 'sources.cleanup.crawl_summary.*').
    def self.summary(report)
      scope = 'sources.cleanup.crawl_summary'
      return I18n.t("#{scope}.refused", reason: I18n.t("sources.cleanup.reasons.#{report.refused}")) if report.refused

      parts = %i[moved archived calendar skipped].filter_map do |key|
        count = report.public_send(key).size
        I18n.t("#{scope}.#{key}", count:, folder: report.backup_dir.to_s) if count.positive?
      end
      I18n.t("#{scope}.prefix", parts: parts.join(', '))
    end

    # - new_files: the files the crawl wrote (Sources::CrawlOutputs: only those may move); since: the crawl start;
    #   until_time: the end of the run window (default: now);
    # - safety: a Sources::Cleanup::Safety (default: built for the season, with +own_key+, inside the crawl slot).
    def initialize(kind:, season_id:, new_files:, since:, data_root: Sources.data_root, own_key: nil, safety: nil, db_index: nil, # rubocop:disable Metrics/ParameterLists
                   until_time: nil)
      @kind = kind.to_s
      @season_id = season_id.to_i
      @new_files = Array(new_files).map(&:to_s)
      @since = since
      @until_time = until_time || Time.current
      @data_root = Pathname.new(data_root)
      @own_key = own_key
      @safety = safety || Cleanup::Safety.new(season_id: @season_id, data_root: @data_root, own_key:, crawl_slot: true)
      @db_index = db_index
    end

    def call
      return Report.empty unless @season_id.positive? && (RESULT_KINDS.include?(@kind) || CALENDAR_KINDS.include?(@kind))

      refused = @safety.run_refusal
      return Report.empty(refused:) if refused

      @report = { moved: [], archived: [], calendar: [], skipped: [] }
      tidy_results if RESULT_KINDS.include?(@kind) && @since
      tidy_calendars if CALENDAR_KINDS.include?(@kind)
      Report.new(**@report, refused: nil, backup_dir: run_folder.relative, moves: run_folder.moves)
    end

    private

    # SeasonBoard::CrawlOutput for each FIN id of the crawl's new LT2 files (it applies the Safety checks itself and
    # never raises).
    def tidy_results
      disk = SeasonBoard::DiskIndex.new(season_id: @season_id, data_dir: @data_root)
      db_index = @db_index || SeasonBoard::DbIndex.new(season_id: @season_id)
      fin_event_ids(disk).each do |fin_event_id|
        outcome = SeasonBoard::CrawlOutput.new(season_id: @season_id, fin_event_id:, since: @since, data_dir: @data_root, db_index:,
                                               disk_index: disk, new_files: @new_files, until_time: @until_time, own_key: @own_key,
                                               safety: @safety, run_folder:).call
        @report[:moved].concat(outcome.removed)
        @report[:archived].concat(outcome.archived)
        @report[:skipped].concat(outcome.skipped)
      end
    end

    # FIN ids of the new '<base>.json' files of results.new/<season> (DiskIndex reads them from the file content).
    def fin_event_ids(disk)
      folder = @data_root.join('results.new', @season_id.to_s).to_s
      @new_files.select { |path| File.dirname(path) == folder && path.end_with?('.json') }
                .filter_map { |path| disk.fin_event_id_for_base(Ops::PipelineSource.base_for(path)) }.uniq
    end

    def tidy_calendars
      outcomes = CalendarTidy.new(season_id: @season_id, data_root: @data_root, safety: @safety, mover:).call
      @report[:calendar].concat(outcomes.select(&:done?).map(&:from))
      @report[:skipped].concat(outcomes.select(&:skipped?).map { |outcome| [outcome.from, outcome.reason] })
    end

    def run_folder
      @run_folder ||= Cleanup::RunFolder.new(root: @safety.guard.root, season_id: @season_id)
    end

    def mover
      @mover ||= Cleanup::Mover.new(guard: @safety.guard, run_folder:)
    end
  end
end
