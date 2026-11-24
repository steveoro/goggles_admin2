# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlerController
  #
  # Crawler tab: the state of the local crawler server (read from its status and PID files, never over HTTP in a page
  # request: SystemStatus::CrawlerProbe), the board and Sources activity (SeasonBoard::ActivityLog, a frame reloaded
  # on every ping), one form per crawl kind (Sources::CrawlKinds; posted to Sources::CrawlsController) and the
  # "Start crawler" button (CrawlerLauncher).
  #
  class CrawlerController < BaseController
    # Manual crawls listed in the activity frame.
    RECENT_LIMIT = 10

    # GET /sources/crawler[?season_id=&sub_menu_type=]
    def show
      @crawler = SystemStatus::CrawlerProbe.new.call
      @season = GogglesDb::Season.find_by(id: season_id)
      @calendar_seasons = calendar_seasons
      @calendar_files = sources_index.files_in('calendar.new', '*.csv')
      @sub_menu_type = params.fetch(:sub_menu_type, nil).presence_in(Sources::CrawlKinds::CALENDAR_SUB_MENUS) || Sources::CrawlKinds::CALENDAR_SUB_MENUS.first
      load_activity
    end

    # GET /sources/crawler/activity (Turbo frame of #show)
    def activity
      load_activity
      render(layout: false)
    end

    # POST /sources/crawler/start
    def start
      flash_symbol, message = CrawlerLauncher.flash_for(CrawlerLauncher.new.ensure_running!)
      flash[flash_symbol] = message
      redirect_to(sources_crawler_path(season_id:), status: :see_other)
    end

    private

    def load_activity
      log = SeasonBoard::ActivityLog.new
      @active = log.active
      @recent = log.all_entries.select(&:source?).sort_by { |entry| -entry.last_timestamp.to_f }.first(RECENT_LIMIT)
    rescue StandardError => e
      Rails.logger.warn("[Sources::CrawlerController] activity log unreadable: #{e.class}: #{e.message}")
      @active = []
      @recent = []
    end

    # The FIN Master seasons with an online calendar (from 2012 on), newest first: [label, id, year text] rows.
    def calendar_seasons
      GogglesDb::Season.joins(:season_type).for_season_type(GogglesDb::SeasonType.mas_fin)
                       .where("begin_date > '2012-01-01'").by_begin_date(:desc)
                       .map { |season| ["#{season.id} – #{season.description}", season.id, Sources::CrawlKinds.year_text_for(season)] }
    end
  end
end
