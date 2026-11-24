# frozen_string_literal: true

module Sources
  #
  # = Sources::CalendarsController
  #
  # Calendars tab (the calendar CSVs of the season: originals, '-sel-' subsets, '-skip' leftovers, crawled ones) and
  # the meeting selection page of one CSV still in 'calendar.new/<season>' (rows with their crawl, manifest and source
  # state, see CrawlerCalendar::Sheet); "Crawl selected" posts to Sources::CrawlsController.
  #
  class CalendarsController < BaseController
    # GET /sources/calendars[?season_id=&focus=]
    def index
      @groups = sources_index.calendars
    end

    # GET /sources/calendars/meetings?path=<calendar CSV>
    def meetings
      @file_path = calendar_path!
      @calendar_season_id = @file_path.dirname.basename.to_s.to_i
      @sheet = CrawlerCalendar::Sheet.new(@file_path.to_s, season_id: @calendar_season_id, data_root: file_guard.root)
      @rows_count = @sheet.row_count
      @pending_manifests = Pathname.new(file_guard.root).join('manifests', @calendar_season_id.to_s).glob('*.pdf').size
    rescue Sources::FileGuard::Refused, CSV::MalformedCSVError, ArgumentError, SystemCallError
      flash[:warning] = I18n.t('data_import.selection.errors.invalid_calendar_file')
      redirect_to(sources_calendars_path(season_id:), status: :see_other)
    end

    private

    # Real path of the requested CSV, which must sit in 'calendar.new/<numeric season>' (raises Refused otherwise).
    def calendar_path!
      path = file_guard.resolve!(params[:path])
      calendar_dir = path.dirname
      valid = path.extname.casecmp?('.csv') && calendar_dir.dirname == file_guard.root.join('calendar.new') &&
              calendar_dir.basename.to_s.match?(/\A\d+\z/)
      raise Sources::FileGuard::Refused.new(:outside, params[:path]) unless valid

      path
    end
  end
end
