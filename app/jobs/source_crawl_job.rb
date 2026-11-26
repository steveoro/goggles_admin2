# frozen_string_literal: true

#
# = SourceCrawlJob
#
# One manual crawl of the Sources crawler tab (phase 15; Sources::CrawlRequest: a FIN calendar, a calendar CSV, a FIN
# meeting, a Microplus, FICR or Go&Swim meeting): starts the Node crawler, waits for the run to end
# (Crawler::RunWatcher, shared with MeetingCrawlJob), lists the new files of the season folders and announces them
# with a toast on every open page (AppNotificationsChannel) and an ops event.
#
# Tracking: SeasonBoard::ActivityLog, kind :crawl, under the request key ('src:<sha1>', see Sources::CrawlRequest#key)
# with a label, so the activity strip and the dashboard "In progress" zone show it; a heartbeat is written at each
# poll, so a long calendar crawl stays busy past ActivityLog::RUNNING_STALE_AFTER. A crawl that ends 'done' also
# records a done :crawl entry under each FIN event id found in its new LT2 result files (the FIN crawler's own output:
# never an LT4 working copy, a phase file or a log rewritten meanwhile by a prepare; ActivityLog#record_many!, one
# write; an id with a busy crawl entry is skipped), so the board rows' "last crawl" is right after a Sources crawl.
#
# Serialisation: the same 'background' worker (one thread) and the same concurrency key AND group as MeetingCrawlJob
# and ManifestExtractJob (Solid Queue prefixes a key with its group), so a manual crawl never runs together with a
# board crawl; priority 10, so the operator's queued board crawls (priority 0) go first, while the automatic calendar
# crawl (15) and the automatic meeting crawls and extractions (20) wait behind it (SeasonBoard::Scheduler, 0.10.103).
# Before starting, it also waits for any crawl the crawler reports as running (5 minutes at most).
#
# Enqueued by Sources::CrawlsController (an operator click) and by SeasonBoard::Scheduler.calendar_crawl! (0.10.103: the
# default FIN 'Eventi' calendar, after a FIN change and once a day); never by a commit or push path. Never raises (no
# retries): any error closes the activity as failed.
#
# Origin (0.10.103): 'operator' (the default, also for a job queued before) or 'auto'. An automatic run crawls only
# the AUTO_KINDS, refuses at start (closing its queued activity entry) while the 'auto_calendar' switch or the master
# switch is off or unreadable (DataFix::Automation fails closed), sends no toast (the ops event and the activity strip
# tell), and fails when a calendar crawl brings no new calendar CSV in calendar.new or only a CSV without data rows (the
# crawler ends "OK, done" on an empty or unsupported page). An operator run of a calendar ends done with a warning
# instead (warning toast and event).
#
class SourceCrawlJob < ApplicationJob # rubocop:disable Metrics/ClassLength
  queue_as :background
  queue_with_priority 10

  # Shared with MeetingCrawlJob and ManifestExtractJob (see there).
  limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour

  # Pause after a FIN crawl, to be gentle with the FIN server (same as MeetingCrawlJob).
  PAUSE_AFTER_CRAWL = MeetingCrawlJob::PAUSE_AFTER_CRAWL
  # DOM id prefix of the end-of-crawl toasts.
  TOAST_DOM_ID_PREFIX = 'sources-crawl-'

  class_attribute :sleeper, default: ->(seconds) { sleep(seconds) }
  class_attribute :clock, default: -> { Time.current }
  class_attribute :crawler_client_factory, default: -> { CrawlerClient.new }
  class_attribute :launcher_factory, default: -> { CrawlerLauncher.new }
  # Base 'crawler/data' folder (nil: Sources.data_root).
  class_attribute :data_dir, default: nil

  Failure = Crawler::RunWatcher::Failure

  # Kinds an automatic run may crawl (0.10.103: the 'Eventi' calendar; never 'calendar_results', which re-crawls every
  # meeting of a calendar).
  AUTO_KINDS = %w[calendar].freeze

  # - kind, season_id, url, file_path, target_event, sub_menu_type, year_text: the Sources::CrawlRequest members;
  # - key: its SeasonBoard::ActivityLog key (default: the request key); label: shown by the activity strip;
  # - origin: 'operator' (default) or 'auto' (see the class notes).
  def perform(kind:, season_id:, key: nil, label: nil, origin: 'operator', **request_args) # rubocop:disable Metrics/AbcSize,Metrics/ParameterLists
    setup(Sources::CrawlRequest.from(request_args.merge(kind:, season_id:)), key, label, origin)
    refuse_automatic!
    activity_log.start!(@key, kind: :crawl, url: @request.target, label: @label)
    message = crawl!
    record_board_crawls
    # (0.10.104: tidy-up of this crawl's redundant output and of the calendar folder; never raises, never fails the crawl)
    message = Sources::CrawlTidy.after_crawl(@request, new_files: @new_files, since: @started_at, data_root: root, own_key: @key, message:,
                                                       on_report: ->(report) { @tidy = report })
    finish!(:done, message)
  rescue Failure => e
    finish!(:failed, e.message)
  rescue StandardError => e
    Rails.logger.error("[SourceCrawlJob] #{@key}: #{e.class}: #{e.message}")
    Rails.logger.debug { e.backtrace&.first(10)&.join("\n") }
    finish!(:failed, "error: #{e.class}: #{e.message}".truncate(200))
  ensure
    finish!(:failed, 'interrupted') unless @finished
    notify_pages
    sleeper.call(PAUSE_AFTER_CRAWL) if @pulled && @request&.fin_server?
  end

  private

  def setup(request, key, label, origin)
    @request = request
    @key = key.presence || request.key
    @label = label.presence || request.label
    @automatic = origin.to_s == 'auto'
    @warning = false
    @finished = false
    @pulled = false
    @new_files = []
  end

  # Runs the crawl; returns the end message (raises Failure).
  def crawl!
    refuse_invalid_request!
    watcher.ensure_crawler!
    watcher.wait_until_idle!(on_wait: -> { heartbeat })
    before = Sources::CrawlOutputs.listing(root, @request.season_id)
    since, baseline = start_crawl!
    final = watcher.wait_for_crawl_end!(since, baseline, timeout: @request.timeout, on_poll: -> { heartbeat })
    raise Failure, "crawler error: #{final.detail}".truncate(200) if final.error?

    @new_files = Sources::CrawlOutputs.new_files(before, Sources::CrawlOutputs.listing(root, @request.season_id), since:)
    end_message
  end

  # The end message (a calendar run is checked first, see #checked_calendar_message).
  def end_message
    @request.kind == 'calendar' ? checked_calendar_message : done_message
  end

  def automatic? = @automatic

  # An automatic run of a kind outside AUTO_KINDS, or with the 'auto_calendar' switch (or the master one) off or
  # unreadable, is refused before anything starts (raises Failure: the queued entry is closed as failed).
  def refuse_automatic!
    return unless automatic?
    raise Failure, I18n.t('sources.crawl.auto_kind_refused', kind: @request.kind) unless AUTO_KINDS.include?(@request.kind)

    raise Failure, I18n.t('pipeline_automation.reasons.automation_paused') unless DataFix::Automation.enabled?(:auto_calendar)
  end

  # The end message of a calendar run: the new files, unless no new calendar CSV with data rows came (an empty or
  # unsupported FIN page still ends "OK, done"): then an automatic run fails (raises Failure) and an operator one ends
  # done with a warning.
  def checked_calendar_message
    problem = calendar_problem
    return done_message unless problem
    raise Failure, problem if automatic?

    @warning = true
    problem
  end

  # Why the run brought no usable calendar (a localized String), or nil.
  def calendar_problem
    csvs = @new_files.select { |path| File.basename(File.dirname(path, 2)) == 'calendar.new' && path.downcase.end_with?('.csv') }
    return I18n.t('sources.crawl.calendar_check.no_file') if csvs.empty?
    return nil if csvs.any? { |path| calendar_rows(path).positive? }

    I18n.t('sources.crawl.calendar_check.no_rows', names: csvs.map { |path| File.basename(path) }.join(', ')).truncate(250)
  end

  # Data rows of a calendar CSV (0 when unreadable).
  def calendar_rows(path)
    CrawlerCalendar::Sheet.new(path, season_id: @request.season_id, data_root: root).row_count
  rescue StandardError
    0
  end

  # The job arguments are checked again (the URL of the kind's site, the calendar CSV inside the data root).
  def refuse_invalid_request!
    problems = @request.errors(guard: Sources::FileGuard.new(root:))
    return if problems.empty?

    raise Failure, "refused: #{problems.map { |key| I18n.t("sources.crawl.errors.#{key}") }.join(', ')}".truncate(200)
  end

  # Returns [crawl start time (whole seconds), status Hash before the call].
  def start_crawl!
    baseline = client.status
    since = clock.call.change(usec: 0)
    @started_at = since
    result = @request.start!(client)
    raise Failure, "crawler API call failed: #{result.error}".truncate(200) unless result.ok?

    @pulled = true
    [since, baseline]
  end

  def done_message
    return I18n.t('sources.crawl.done.none') if @new_files.empty?

    names = @new_files.map { |path| File.basename(path) }
    I18n.t('sources.crawl.done.files', count: names.size, names: names.first(5).join(', ')).truncate(250)
  end

  # A done :crawl entry under each FIN event id read from the new LT2 result files (never raises).
  def record_board_crawls
    probe = SeasonBoard::SourceProbe.new
    fin_ids = @new_files.select { |path| crawled_lt2_file?(path, probe) }.filter_map { |path| probe.call(path, full: false)[:fin_event_id] }
    origin = automatic? ? :auto : :manual
    activity_log.record_many!(fin_ids, kind: :crawl, status: :done, origin:, message: @label, started_at: @started_at) if fin_ids.any?
  rescue StandardError => e
    Rails.logger.warn("[SourceCrawlJob] board crawl entries not recorded: #{e.class}: #{e.message}")
  end

  # A '<base>.json' of results.new holding LT2 data (what the FIN crawler writes): not an LT4 working copy, a phase
  # file, a backup or an LT4-content file.
  def crawled_lt2_file?(path, probe)
    name = File.basename(path)
    return false unless File.basename(File.dirname(path, 2)) == 'results.new' && name.end_with?('.json') && !name.end_with?('-lt4.json')
    return false if SeasonBoard::DiskIndex::PHASE_REGEXP.match?(name) || SeasonBoard::DiskIndex::SKIPPED_JSON_REGEXP.match?(name)

    probe.layout_type(path) == 2
  end

  def heartbeat
    activity_log.heartbeat!(@key, kind: :crawl)
  rescue StandardError => e
    Rails.logger.warn("[SourceCrawlJob] heartbeat not written: #{e.class}: #{e.message}")
  end

  def finish!(status, message)
    return if @finished || @key.blank?

    @finished = true
    @status = status
    @message = message
    record_finish_event(status, message)
    activity_log.finish!(@key, kind: :crawl, status:, message:)
  rescue StandardError => e
    Rails.logger.error("[SourceCrawlJob] cannot update the activity log: #{e.class}: #{e.message}")
  end

  # Appends 'sources.crawl_finished' / 'sources.crawl_failed' to the ops event log (never raises; level 'warning' for a
  # calendar run that brought no usable calendar, 'origin': operator | auto).
  def record_finish_event(status, message)
    Ops.safely do
      done = status.to_s == 'done'
      Ops.record_event!(
        kind: done ? 'sources.crawl_finished' : 'sources.crawl_failed', level: finish_level(done), actor: 'job',
        season_id: @request&.season_id&.positive? ? @request.season_id : nil, subject_type: 'source_crawl', subject_key: @key,
        data: { 'kind' => @request&.kind, 'label' => @label, 'status' => status.to_s, 'message' => message,
                'files' => @new_files.map { |path| File.basename(path) }, 'origin' => automatic? ? 'auto' : 'operator',
                'cleanup' => cleanup_data }.compact,
        link_path: toast_link_path
      )
    end
  end

  # The tidy-up of this run for the finish event (nil when nothing moved): where the moved files went (with its MOVES.txt)
  # and how many moves were made.
  def cleanup_data
    return nil unless @tidy&.any?

    { 'backup_dir' => @tidy.backup_dir.to_s.presence, 'moves' => @tidy.moves.to_i }.compact
  end

  def finish_level(done)
    return 'error' unless done

    @warning ? 'warning' : 'success'
  end

  # End-of-crawl toast on every open page (an operator run only), a board refresh (the new files may change its rows)
  # and the next pipeline planner pass (it prepares a FIN meeting crawled here like a board one, and after a calendar
  # crawl crawls the meetings of a FIN change that got their link from it). Never raises.
  def notify_pages
    broadcast_toast if @finished && !automatic?
    season_id = @request&.season_id
    SeasonBoard::Snapshot.invalidate!(season_id) if season_id&.positive?
    SeasonBoard::Notifier.ping
    PipelinePlannerJob.enqueue_after(self.class.name)
  rescue StandardError => e
    Rails.logger.warn("[SourceCrawlJob] notification failed: #{e.class}: #{e.message}")
  end

  def broadcast_toast
    status = @warning && @status.to_s == 'done' ? :warning : @status
    component = Sources::CrawlToastComponent.new(status:, label: @label, message: @message, files: @new_files,
                                                 link_path: toast_link_path)
    html = ApplicationController.render(component, layout: false)
    ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: "#{TOAST_DOM_ID_PREFIX}#{@key.delete_prefix('src:')}", html: })
  end

  # The Sources tab listing the first new file (focused), else the crawler tab.
  def toast_link_path
    Sources::Paths.focus_path(@new_files.first, season_id: @request&.season_id, root:) ||
      Rails.application.routes.url_helpers.sources_crawler_path
  end

  def root
    Pathname.new(data_dir || Sources.data_root)
  end

  def watcher
    @watcher ||= Crawler::RunWatcher.new(client:, launcher_factory:, sleeper:, clock:)
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end

  def client
    @client ||= crawler_client_factory.call
  end
end
