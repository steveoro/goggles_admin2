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
# poll, so a long calendar crawl stays busy past ActivityLog::RUNNING_STALE_AFTER.
#
# Serialisation: the same 'background' worker (one thread) and the same concurrency key AND group as MeetingCrawlJob
# and ManifestExtractJob (Solid Queue prefixes a key with its group), so a manual crawl never runs together with a
# board crawl; priority 10, so the queued board crawls (priority 0) go first. Before starting, it also waits for any
# crawl the crawler reports as running (5 minutes at most).
#
# Enqueued only by Sources::CrawlsController (an operator click); never by a commit or push path. Never raises (no
# retries): any error closes the activity as failed.
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

  # - kind, season_id, url, file_path, target_event, sub_menu_type, year_text: the Sources::CrawlRequest members;
  # - key: its SeasonBoard::ActivityLog key (default: the request key); label: shown by the activity strip.
  def perform(kind:, season_id:, key: nil, label: nil, **request_args) # rubocop:disable Metrics/AbcSize
    setup(Sources::CrawlRequest.from(request_args.merge(kind:, season_id:)), key, label)
    activity_log.start!(@key, kind: :crawl, url: @request.target, label: @label)
    finish!(:done, crawl!)
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

  def setup(request, key, label)
    @request = request
    @key = key.presence || request.key
    @label = label.presence || request.label
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
    done_message
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

  # Appends 'sources.crawl_finished' / 'sources.crawl_failed' to the ops event log (never raises).
  def record_finish_event(status, message)
    Ops.safely do
      done = status.to_s == 'done'
      Ops.record_event!(
        kind: done ? 'sources.crawl_finished' : 'sources.crawl_failed', level: done ? 'success' : 'error', actor: 'job',
        season_id: @request&.season_id&.positive? ? @request.season_id : nil, subject_type: 'source_crawl', subject_key: @key,
        data: { 'kind' => @request&.kind, 'label' => @label, 'status' => status.to_s, 'message' => message,
                'files' => @new_files.map { |path| File.basename(path) } },
        link_path: toast_link_path
      )
    end
  end

  # End-of-crawl toast on every open page, a board refresh (the new files may change its rows) and the next pipeline
  # planner pass (it prepares a FIN meeting crawled here like a board one). Never raises.
  def notify_pages
    broadcast_toast if @finished
    season_id = @request&.season_id
    SeasonBoard::Snapshot.invalidate!(season_id) if season_id&.positive?
    SeasonBoard::Notifier.ping
    PipelinePlannerJob.enqueue_after(self.class.name)
  rescue StandardError => e
    Rails.logger.warn("[SourceCrawlJob] notification failed: #{e.class}: #{e.message}")
  end

  def broadcast_toast
    component = Sources::CrawlToastComponent.new(status: @status, label: @label, message: @message, files: @new_files,
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
