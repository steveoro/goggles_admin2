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

  # Base URL for FICR results:
  FICR_RESULTS_BASE_URL = 'https://nuoto.ficr.it/'
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
  def run_crawler_api # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
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
      api_endpoint = if layout == 4
                       'pull_results_microplus'
                     elsif layout == 5
                       'pull_results_ficr'
                     else
                       'pull_results'
                     end
      api_params = case layout
                   when 4
                     api_params.merge(meeting_url: crawler_params['target_url'],
                                      target_event: crawler_params['target_event'])
                   when 2, 5
                     # Direct FICR (LT4) or FIN (LT2) single meeting URL:
                     api_params.merge(meeting_url: crawler_params['target_url'])
                   else
                     # Legacy result modes using a local calendar CSV file (layout 1/3):
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
    season_id = SeasonDefaults.default_season_id unless season_id.positive?

    call_crawler_api(
      'pull_results',
      get_params: {
        season_id:,
        file_path: file_params['file_path'],
        layout: result_layout_for(season_id)
      }
    )
    redirect_to(pull_index_path) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET] Meeting selection page for a calendar CSV file.
  #
  # Shows one row per meeting listed in the CSV, with the derived crawler state
  # (result URL present, manifest already downloaded/extracted, source file
  # already generated) so the operator can pick which meetings to crawl.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the calendar file to be displayed
  #
  def calendar_meetings
    unless valid_calendar_csv_path?(selection_params[:file_path])
      flash[:warning] = I18n.t('data_import.selection.errors.invalid_calendar_file')
      redirect_to(pull_calendar_files_path) && return
    end

    @file_path = selection_params[:file_path]
    @season_id = season_id_from_path(@file_path)
    @sheet = safe_sheet(@file_path, @season_id)
    unless @sheet
      flash[:warning] = I18n.t('data_import.selection.errors.invalid_calendar_file')
      redirect_to(pull_calendar_files_path) && return
    end
    @pending_manifests = pending_manifest_count(@season_id)
    @extraction_running = PdfManifests::BatchRunner.running?
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Runs the result crawler on a bespoke subset of the specified calendar
  # CSV file, containing only the meeting rows selected on the selection page.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the source calendar file
  # - <tt>rows_count</tt>: total rows at render time (integrity guard)
  # - <tt>selected_rows[]</tt>: indexes of the rows to be crawled
  #
  def process_selected_meetings
    file_path = selection_params[:file_path]
    season_id = season_id_from_path(file_path)
    indexes = Array(selection_params[:selected_rows]).map(&:to_i)
    sheet = valid_calendar_csv_path?(file_path) && safe_sheet(file_path, season_id)

    if (reason = selection_rejection(sheet, indexes))
      flash[:warning] = I18n.t("data_import.selection.errors.#{reason}")
      redirect_to(selection_redirect_path(reason, file_path)) && return
    end

    subset_path = sheet.write_subset(indexes)
    call_crawler_api(
      'pull_results',
      get_params: {
        season_id:,
        file_path: subset_path,
        layout: result_layout_for(season_id)
      }
    )
    redirect_to(pull_index_path) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Starts a background manifest-extraction batch for the specified season.
  #
  # Runs the same pipeline as 'rake manifests:extract' inside a daemon thread;
  # progress is reported on a status file polled through #extraction_status.
  #
  # == Params:
  # - <tt>season_id</tt>: the target season
  # - <tt>file_path</tt>: optional calendar file path used for the redirect back
  #
  def extract_manifests
    redirect_path = selection_params[:file_path].present? ? pull_calendar_meetings_path(file_path: selection_params[:file_path]) : pull_index_path

    if PdfManifests::BatchRunner.running?
      flash[:warning] = I18n.t('data_import.selection.extraction.already_running')
      redirect_to(redirect_path) && return
    end

    runner = PdfManifests::BatchRunner.new(season_id: selection_params[:season_id].to_i)
    case runner.preflight_error
    when :ollama_unavailable
      flash[:warning] = I18n.t('data_import.selection.extraction.ollama_unavailable')
    when :model_missing
      flash[:warning] = I18n.t('data_import.selection.extraction.model_missing', model: runner.client.model)
    when :no_manifests
      flash[:warning] = I18n.t('data_import.selection.extraction.no_manifests')
    else
      runner.start_in_thread! # daemon thread; UI polls #extraction_status for progress
      flash[:info] = I18n.t('data_import.selection.extraction.started', count: runner.pdf_list.size)
    end
    redirect_to(redirect_path) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET] JSON status of the manifest-extraction batch (polled by the UI).
  #
  # == Params:
  # - <tt>season_id</tt>: the target season (for the pending manifests count)
  #
  def extraction_status
    render json: {
      running: PdfManifests::BatchRunner.running?,
      pending: pending_manifest_count(params[:season_id].to_i),
      status: PdfManifests::BatchRunner.read_status
    }
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Strong parameters checking for crawler API calls.
  def crawler_params
    params.permit(:start_url, :season_id, :sub_menu_type, :year_text,
                  :layout, :layout_id, :target_url, :target_event)
  end

  # Strong parameters checking for calendar meeting-selection actions.
  def selection_params
    params.permit(:file_path, :season_id, :rows_count, selected_rows: [])
  end

  # Symbol naming the i18n error key blocking the given selection, or nil when
  # the selected rows can be crawled. 'sheet' is expected to be already loaded
  # (or nil/false when the path validation or the CSV parsing failed).
  def selection_rejection(sheet, indexes)
    return :invalid_calendar_file unless sheet
    return :no_selection if indexes.empty?
    return :file_changed if sheet.row_count != selection_params[:rows_count].to_i

    nil
  end

  # Redirect target for a rejected selection: calendar file list for unusable
  # files, back to the selection page otherwise.
  def selection_redirect_path(reason, file_path)
    return pull_calendar_files_path if reason == :invalid_calendar_file

    pull_calendar_meetings_path(file_path: file_path)
  end

  # Parsed calendar Sheet, or nil when the file can't be read as a CSV.
  def safe_sheet(file_path, season_id)
    CrawlerCalendar::Sheet.new(file_path, season_id: season_id)
  rescue StandardError => e
    Rails.logger.warn("[PullController] unreadable calendar file #{file_path}: #{e.message}")
    nil
  end

  # TRUE when file_path points to an existing .csv file under crawler/data/calendar.new/
  # (the only folder consumed by the results crawler lifecycle). Symlinks are resolved
  # so a link pointing outside the folder is rejected.
  def valid_calendar_csv_path?(file_path)
    return false if file_path.blank? || !File.file?(file_path.to_s)

    root = Rails.root.join('crawler/data/calendar.new').realpath
    File.realpath(file_path.to_s).start_with?("#{root}#{File::SEPARATOR}") &&
      File.extname(file_path.to_s).casecmp?('.csv')
  rescue SystemCallError
    false
  end

  # Season ID encoded in the parent dir name (calendar.*<season>/file.csv),
  # falling back to the latest MASFIN season.
  def season_id_from_path(file_path)
    season_id = File.dirname(file_path.to_s).split('/').last.to_i
    season_id.positive? ? season_id : SeasonDefaults.default_season_id
  end

  # Result-page layout bound to the season (layouts 2 & 3 are equivalent for
  # result pages, so season_id >= 182 uses layout 2).
  def result_layout_for(season_id)
    season_id < 182 ? 1 : 2
  end

  # Number of PDF manifests still pending extraction for the season.
  def pending_manifest_count(season_id)
    return 0 unless season_id.to_i.positive?

    Rails.root.glob("crawler/data/manifests/#{season_id.to_i}/*.pdf").size
  end

  # Prepares the <tt>@season_list</tt> member variable for the view, as an Array of Hash objects
  # having the required keys for setting up the <tt>LegacyAutoCompleteComponent</tt> data payload.
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
  # as an Array of Hash objects having the required keys for setting up the <tt>LegacyAutoCompleteComponent</tt> data payload.
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

      # FIN direct meeting result URL (layout 2, results-crawler.js):
      # https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/<sub_page_url>
      {
        id: 2,
        label: I18n.t('data_import.config.crawler_fin_results_lt2'),
        base_url: "#{FIN_RESULTS_BASE_URL} (+<LINK>)"
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
      },

      # FICR direct meeting result URL (layout 5, LT4 output):
      # https://nuoto.ficr.it/#/NUO/tempi/<meeting>/<year>/<eqCode>/<meetingId>/<category>/<event>
      {
        id: 5,
        label: I18n.t('data_import.config.crawler_ficr_results'),
        base_url: "#{FICR_RESULTS_BASE_URL} (+<LINK>)"
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
