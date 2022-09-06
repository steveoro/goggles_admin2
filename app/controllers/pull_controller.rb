# frozen_string_literal: true

require 'csv'

# = PullController: crawler dashboard
#
# Crawler actions and status.
#
class PullController < FileListController
  # URL for the Crawler server API
  CRAWLER_API_URL = 'http://localhost:7000/'
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
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Run the Meeting Calendar crawler through an API call.
  #
  # Uses the #crawler_params for the API call.
  # The layout type of the calendar is auto-detected by the crawler itself.
  #
  def run_calendar_crawler
    unless crawler_params['start_url'].present? && crawler_params['season_id'].present?
      flash[:warning] = I18n.t('data_import.errors.missing_url_or_season_id')
      redirect_to(pull_index_path) && return
    end

    call_crawler_api(
      'pull_calendar',
      get_params: {
        season_id: crawler_params['season_id'],
        start_url: crawler_params['start_url']
      }
    )
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
        season_id: season_id,
        file_path: file_params['file_path'],
        layout: season_id < 182 ? 1 : 2 # layouts 2 & 3 are equivalent for result pages
      }
    )
    redirect_to(pull_index_path) && return

    # TODO: *******************************************************
    # Separate:
    # 3. to process results, scan local DB for calendar rows, after selecting the season
    # 4. retrieve results using new ResultsCrawler & local crawler server API

    # To process result files:
    # 5. for each JSON file, create a new MACROTRANSACTION on localhost, logging the needed SQL (local DB must be in-sync w/ remote DB, same env)
    # 6. make data import solver to act on specific localhost entities and log the outcome
    # 7. for each solved data-import MACRO transaction, create a single batch SQL query for remote upload
    # 8. upload the batch SQL using the existing Capistrano task
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Strong parameters checking for crawler API calls.
  def crawler_params
    params.permit(:start_url, :season_id, :layout)
  end

  # Prepares the <tt>@season_list</tt> member variable for the view, as an Array of Hash objects
  # having the required keys for setting up the <tt>AutoCompleteComponent</tt> data payload.
  #
  # == Params
  # - <tt>seasons</tt>: the AR list of rows to be processed
  # - <tt>current_season_id</tt>: the ID of the current Season
  #
  def prepare_season_list(seasons, current_season_id)
    base_calendar_url = 'https://www.federnuoto.it/home/master/circuito-supermaster'
    @season_list = seasons.map do |season|
      if season.id == current_season_id
        {
          id: season.id,
          season_label: season.decorate.display_label,
          description: season.description,
          layout: 3, # current season layout:  table w/ links + row-wide year separator
          calendar_url: "#{base_calendar_url}/riepilogo-eventi.html"
        }
      else
        year1 = season.begin_date.year
        year2 = season.end_date.year
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
          calendar_url: "#{base_calendar_url}/archivio-2012-2021/stagione-#{year1}-#{year2}.html"
        }
      end
    end
  end

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
    hdrs.merge!('Content-Type' => 'application/json')
    # DEBUG
    Rails.logger.debug("\r\n-- call_crawler_api headers:")
    Rails.logger.debug(hdrs.inspect)
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
