# frozen_string_literal: true

require 'csv'

# = PullController: crawler dashboard
#
# Crawler actions and status.
#
class PullController < FileListController
  # URL for the Crawler server API
  CRAWLER_API_URL = 'http://localhost:7000/'

  # Base URL for FIN event calendars:
  FIN_CALENDAR_BASE_URL = 'https://www.federnuoto.it/home/master.html'

  # Base URL for FIN results:
  FIN_RESULTS_BASE_URL = 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/'

  # Base URL for Microplus results:
  MICROPLUS_RESULTS_BASE_URL = 'https://fin2025.microplustiming.com/'
  #-- -------------------------------------------------------------------------
  #++

  # [GET] Main crawler server status dashboard w/ log.
  # Allows to launch the calendar crawling through a local API call.
  #
  def index
    # Prepare the domain for the Season selection dropdown:
    # (Remote FIN Caledar URL are available only for years >= 2012)
    seasons = GogglesDb::Season.joins(:season_type).includes(:season_type)
                               .for_season_type(GogglesDb::SeasonType.mas_fin)
                               .where("begin_date > '2012-01-01'")
                               .by_begin_date(:desc)
    prepare_season_list(seasons, seasons.first.id)
    prepare_url_base_list
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Run the Meeting Calendar crawler through an API call.
  #
  # Uses the #crawler_params for the API call.
  # The layout type of the calendar is auto-detected by the crawler itself.
  #
  def run_crawler_api # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    unless crawler_params['sub_menu_type'].present? && crawler_params['season_id'].present?
      flash[:warning] = I18n.t('data_import.errors.missing_url_or_season_id')
      redirect_to(pull_index_path) && return
    end

    # For layout types != 0, 'target_url' must be completed by hand (it's a placeholder):
    target_url_valid = crawler_params['target_url'].present? && !crawler_params['target_url'].match?(%r{/\s\(\+})
    if crawler_params['layout_id'] == '0' || crawler_params['layout_id'].blank? # defaults to layout type "auto"/calendar
      call_crawler_api(
        'pull_calendar',
        get_params: {
          season_id: crawler_params['season_id'],
          # New base URL for (FIN) calendars must be fixed, crawler will simulate menu clicking:
          start_url: FIN_CALENDAR_BASE_URL,
          sub_menu_type: crawler_params['sub_menu_type'],
          year_text: crawler_params['year_text']
        }
      )

    elsif target_url_valid
      layout = crawler_params['layout_id'].to_i
      api_params = { season_id: crawler_params['season_id'], layout: }
      api_endpoint = layout == 4 ? 'pull_results_microplus' : 'pull_results'
      api_params = if layout == 4
                     api_params.merge(meeting_url: crawler_params['target_url'],
                                      target_event: crawler_params['target_event'])
                   else
                     # TODO: support actual target_url in 'pull_results' implementation instead of just 'file_path'.
                     #       Current implementation: runs the crawler for layout 3 iterating on each row of the CSV calendar file, where each row has a target URL.
                     #       If the 'file_path' parameter is a URL instead of a local file, it should run the results crawler directly on the specified parameter,
                     #       instead of parsing the CSV and looping on each row.
                     api_params.merge(file_path: crawler_params['target_url'])
                   end
      call_crawler_api(api_endpoint, get_params: api_params)

    else
      flash[:warning] = I18n.t('data_import.errors.unsupported_layout_or_incomplete_url')
      redirect_to(pull_index_path) && return
    end

    redirect_to(pull_index_path) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Runs the result crawler using the CSV file specified by the given <tt>file_path</tt> parameter
  # as meeting list/calendar.
  #
  # The layout type of the result pages is detected using the season_id parameter.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the calendar file to be processed
  #
  def process_calendar_file
    if file_params['file_path'].blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    season_id = File.dirname(file_params['file_path']).split('/').last.to_i
    season_id = 212 unless season_id.positive?

    call_crawler_api(
      'pull_results',
      get_params: {
        season_id:,
        file_path: file_params['file_path'],
        layout: season_id < 182 ? 1 : 2 # layouts 2 & 3 are equivalent for result pages
      }
    )
    redirect_to(pull_index_path) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Strong parameters checking for crawler API calls.
  def crawler_params
    params.permit(:start_url, :season_id, :sub_menu_type, :year_text,
                  :layout, :layout_id, :target_url, :target_event)
  end

  # Prepares the <tt>@season_list</tt> member variable for the view, as an Array of Hash objects
  # having the required keys for setting up the <tt>AutoCompleteComponent</tt> data payload.
  #
  # == Params
  # - <tt>seasons</tt>: the AR list of rows to be processed
  # - <tt>current_season_id</tt>: the ID of the current Season
  #
  def prepare_season_list(seasons, current_season_id)
    # New base URL is fixed! New site version disables direct links and needs to be browsed "on site"
    # (old base URL: 'https://www.federnuoto.it/home/master/circuito-supermaster', with variable direct link)

    @season_list = seasons.map do |season|
      year1 = season.begin_date.year
      year2 = season.end_date.year
      if season.id == current_season_id
        {
          id: season.id,
          season_label: season.decorate.display_label,
          description: season.description,
          layout: 3, # current season layout:  table w/ links + row-wide year separator
          year_text: "#{year1}/#{year2}"
          # Old param (subseeded by page version Oct 2022):
          # calendar_url: "#{base_calendar_url}/riepilogo-eventi.html"
        }
      else
        page_layout = if year1 < 2018
                        1 # older seasons layout: row-wide month separator
                      else
                        2 # 2018+ layout (!= current season): season header and dates w/ months & yea
                      end
        {
          id: season.id,
          season_label: season.decorate.display_label,
          description: season.description,
          layout: page_layout,
          year_text: "#{year1}/#{year2}"
          # Old param (subseeded by page version Oct 2022):
          # calendar_url: "#{base_calendar_url}/archivio-2012-2021/stagione-#{year1}-#{year2}.html"
        }
      end
    end
  end

  # Similar to the one above, prepares the <tt>@url_base_list</tt> member variable for the view,
  # as an Array of Hash objects having the required keys for setting up the <tt>AutoCompleteComponent</tt> data payload.
  #
  def prepare_url_base_list
    @url_base_list = [
      # FIN calendar base URL (constant, layout auto, handled by calendar-crawler.js):
      # https://www.federnuoto.it/home/master.html
      {
        id: 0,
        label: I18n.t('data_import.config.crawler_fin_calendar'),
        base_url: FIN_CALENDAR_BASE_URL
      },

      # FIN "current season" meeting base URL (layout 3, results-crawler.js):
      # https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/<sub_page_url>
      {
        id: 3,
        label: I18n.t('data_import.config.crawler_fin_results'),
        base_url: "#{FIN_RESULTS_BASE_URL} (+<LINK>)"
      },

      # Sample valid base URLs for Microplus crawler (microplus-crawler.js):
      # season_id, url
      # 242, https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php
      # 242, https://fin2025.microplustiming.com/MA_2025_05_30_Gorizia.php
      # 232, https://fin2024.microplustiming.com/MAS_2024_06_25-30_Riccione.php
      # 232, https://fin2023.microplustiming.com/MAS_2023_12_08-10_Torino.php
      # 222, https://fin2023.microplustiming.com/MAS_2023_06_27-07_02_Riccione.php
      # 212, https://fin2022.microplustiming.com/MAS_2022_06_28-07_03_Riccione.php
      # 182, https://fin2019.microplustiming.com/MA_2019_06_25-30_Riccione.php
      # 172, http://fin2018.microplustiming.com/masterpalermo2018/
      {
        id: 4,
        label: I18n.t('data_import.config.crawler_microplus'),
        base_url: "#{MICROPLUS_RESULTS_BASE_URL} (+<PAGE>.php)"
      }
    ]
  end
  #-- -------------------------------------------------------------------------
  #++

  # Sends a command through the crawler API.
  # Requires the Crawler server already running on localhost:7000.
  #
  # == Params:
  # - <tt>cmd_endpoint</tt>: the API endpoint to call (i.e.: 'pull_calendar')
  # - <tt>get_params</tt>: GET parameters to be sent with the call
  #
  # === Note:
  # The crawler API is implemented as pure GET-only requests mainly because:
  # - it's supposed to be run on localhost only (no need to use a full-blown API implementation)
  # - in case of any PUT, POST or DELETE payload, the NodeJs server middleware expects an encoded
  #   form data as payload and in this case this is certainly overkill.
  #
  def call_crawler_api(cmd_endpoint, get_params: nil)
    hdrs = get_params.present? ? { 'params' => get_params.to_h.stringify_keys! } : {}
    hdrs['Content-Type'] = 'application/json'
    # DEBUG
    logger.debug("\r\n-- call_crawler_api headers:")
    logger.debug(hdrs.inspect)
    res = RestClient::Request.execute(
      method: :get,
      url: "#{CRAWLER_API_URL}#{cmd_endpoint}",
      headers: hdrs
    )
    # DEBUG
    logger.debug("\r\n*** response: #{res.body}")
  rescue RestClient::ExceptionWithResponse => e
    flash[:error] = e.message
  end
end
