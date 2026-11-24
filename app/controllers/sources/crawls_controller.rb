# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlsController
  #
  # POST /sources/crawls: queues one manual crawl (SourceCrawlJob) after checking it (Sources::CrawlRequest: kind,
  # season, URL of the kind's site, calendar CSV inside 'calendar.new/<season>'). It never calls the crawler: the job
  # does, on the 'background' worker, one crawl at a time with the board crawls (same concurrency key and group).
  #
  # A calendar CSV crawl posted by the meeting selection page (+rows_count+ and +selected_rows[]+) first writes a
  # '-sel-' subset of the CSV next to it (CrawlerCalendar::Sheet#write_subset) and crawls that one; +rows_count+
  # guards against a file changed under the page.
  #
  class CrawlsController < BaseController
    # POST /sources/crawls
    def create
      request_values = crawl_values
      return if performed?

      crawl = Sources::CrawlRequest.from(request_values)
      errors = crawl.errors(guard: file_guard)
      return refuse(errors.map { |key| I18n.t("sources.crawl.errors.#{key}") }.join(', ')) if errors.any?

      enqueue(crawl)
    end

    private

    def crawl_params
      params.permit(:kind, :season_id, :url, :file_path, :target_event, :sub_menu_type, :year_text, :rows_count, selected_rows: [])
    end

    # The request values, with the real calendar CSV path (and its subset written for a selection).
    def crawl_values
      values = crawl_params.to_h.symbolize_keys.except(:rows_count, :selected_rows)
      values[:season_id] ||= season_id
      if values[:kind] == 'calendar' && values[:year_text].blank?
        values[:year_text] =
          Sources::CrawlKinds.year_text_for(GogglesDb::Season.find_by(id: values[:season_id]))
      end
      values[:file_path] = calendar_file(values) if values[:kind] == 'calendar_results'
      values
    end

    # Real path of the calendar CSV to crawl: the given one, or the '-sel-' subset of the selected rows.
    def calendar_file(values) # rubocop:disable Metrics/AbcSize
      path = file_guard.resolve!(values[:file_path]).to_s
      return path if crawl_params[:rows_count].blank?

      sheet = CrawlerCalendar::Sheet.new(path, season_id: values[:season_id].to_i, data_root: file_guard.root)
      indexes = Array(crawl_params[:selected_rows]).compact_blank.map(&:to_i)
      reason = selection_rejection(sheet, indexes)
      return sheet.write_subset(indexes).to_s unless reason

      flash[:warning] = I18n.t("data_import.selection.errors.#{reason}")
      redirect_to(sources_calendar_meetings_path(path: file_guard.relative(path)), status: :see_other)
      nil
    rescue CSV::MalformedCSVError, ArgumentError, SystemCallError
      refuse(I18n.t('data_import.selection.errors.invalid_calendar_file'))
      nil
    end

    def selection_rejection(sheet, indexes)
      return :no_selection if indexes.empty?
      return :file_changed if sheet.row_count != crawl_params[:rows_count].to_i

      nil
    end

    def enqueue(crawl) # rubocop:disable Metrics/AbcSize
      log = SeasonBoard::ActivityLog.new
      return refuse(I18n.t('sources.crawl.already_queued', label: crawl.label)) if log.busy?(crawl.key, kind: :crawl)

      ahead = log.active.count { |entry| entry.kind == :crawl }
      log.queue!(crawl.key, kind: :crawl, origin: :manual, url: crawl.target, label: crawl.label)
      begin
        SourceCrawlJob.perform_later(**crawl.to_job_args, key: crawl.key, label: crawl.label)
      rescue StandardError => e
        log.finish!(crawl.key, kind: :crawl, status: :failed, message: "enqueue failed: #{e.message}".truncate(200))
        raise
      end
      SeasonBoard::Notifier.ping
      flash[:notice] = I18n.t(ahead.positive? ? 'sources.crawl.queued_behind' : 'sources.crawl.queued', label: crawl.label, count: ahead)
      redirect_to(sources_crawler_path(season_id: crawl.season_id), status: :see_other)
    end

    def refuse(message)
      flash[:warning] = message
      redirect_to(sources_crawler_path(season_id:), status: :see_other)
    end
  end
end
