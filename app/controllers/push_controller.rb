# frozen_string_literal: true

# = PushController: data-import pre-production "push" dashboard
#
# Recap & show pending data-import data before the final push to production.
# (Legacy data-import step 2 & 3)
#
class PushController < FileListController
  include FileCounter
  include PushEventRecorder

  # Members @data_hash & @solver must be set for all actions (redirects if the JSON parsing fails)
  before_action :set_file_path, except: :index
  before_action :parse_file_contents, :prepare_solver, only: :prepare

  # [GET] Data-import push dashboard.
  # Relies on FileListController#result_files.
  #
  # === Sets/Uses:
  # - @filter, to force-display batch files only
  #
  # === Params:
  # - :parent_folder => selects which parent folder (default: 'results.new')
  #
  def index
    @filter = '*.sql'
    result_files
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Data-import push/prepare.
  #
  # Prepares and stores a single-transaction SQL batch file for an imported meeting with
  # all its results and bindings.
  #
  # === Params:
  # - :file_path => path to the JSON data file storing the solved meeting with its details
  #
  # === Requires/Uses:
  # See before actions for these:
  # - @file_path, containing the JSON data
  # - @data_hash, parsed data from @file_path
  # - @season, correct Season
  # - @solver, uses @data_hash & @season
  #
  # rubocop:disable-next Metrics/AbcSize
  def prepare
    # Prepare the SQL batch file logging each statement:
    @committer = Import::MacroCommitter.new(solver: @solver)
    @committer.commit_all

    curr_dir = File.dirname(@file_path)
    sent_dir = curr_dir.to_s.gsub('results.new', 'results.sent')
    dest_file = File.basename(@file_path)
    done_pathname = @file_path.to_s.gsub('results.new', 'results.done') # JSON backup copy (before IDs)

    # Prepare a sequential counter prefix for the uploadable batch file:
    last_counter = compute_file_counter(curr_dir, sent_dir)
    dest_file = "#{format('%04d', last_counter + 1)}-#{File.basename(dest_file.to_s.gsub('.json', '.sql'))}"

    # Move last phase's JSON file (before IDs were set) into 'done' as a backup:
    FileUtils.mkdir_p(File.dirname(done_pathname)) # First, ensure existence of the destination path
    File.rename(@file_path, done_pathname)
    # Save also the committed data to another file (storing the resulting actual IDs):
    File.write(done_pathname.to_s.gsub('.json', '.committed.json'), @solver.data.to_json)

    # Save the SQL batch file with the sequential prefix in the same 'results.new' directory:
    File.open(File.join(curr_dir, dest_file), 'w+') do |f|
      @committer.sql_log.each do |sql_statement|
        f.write(sql_statement)
        f.write("\r\n")
      end
    end

    flash[:notice] = I18n.t('data_import.push.msg_prepare_batch_ok')
    redirect_to(push_index_path)
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Data-import push/send.
  #
  # Allows single batch file push (or all the files of a 'results.new' folder).
  # "Consumes" the local batch file afterwards by moving it from 'results.new' to 'results.sent'
  # (the target folder includes the season code as subfolder).
  # Files outside 'results.new' are refused.
  #
  # === Params:
  # - :file_path => path to the SQL file storing the data-import transaction.
  #
  # === Requires:
  # See before actions for these:
  # - @file_path, containing the SQL batch file to be sent.
  #
  # rubocop:disable-next Metrics/AbcSize
  def upload
    return unless file_path_allowed? && file_path_pending?

    # Handle file globs (same recursive listing & sorting as FileListController#result_files):
    if @file_path.ends_with?('*.sql')
      files = Rails.root.glob("crawler/#{relative_to_crawler(File.dirname(@file_path))}/**/*.sql").sort
      files.each_with_index do |file_path, idx|
        ActionCable.server.broadcast('ImportStatusChannel', { msg: "sending '#{file_path}'", progress: idx + 1, total: files.count })
        push_file_and_move(file_path)
        if flash[:error].present?
          flash[:error] = "#{flash[:error]} - file: '#{file_path}'"
          break
        end
      end
      flash[:info] = I18n.t('data_import.push.all_sql_files_ok') if flash[:error].blank?
    else
      push_file_and_move(@file_path)
    end

    redirect_to(push_index_path(upload_folder_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Returns the given path stripped of everything up to (and including) 'crawler/'.
  def relative_to_crawler(path)
    path.to_s.split('crawler/').last
  end

  # Returns the absolute pathname (inside crawler/) for the specified path, which
  # can be either absolute or relative to crawler/ (the trailing '*.sql' glob is ignored).
  def resolve_crawler_path(path)
    base = path.to_s.ends_with?('*.sql') ? File.dirname(path.to_s) : path.to_s
    Rails.root.join('crawler', relative_to_crawler(base)).cleanpath
  end

  # True only when @file_path resolves under crawler/data; flashes a warning and redirects otherwise.
  def file_path_allowed?
    data_root = Rails.root.join('crawler/data').to_s
    return true if resolve_crawler_path(@file_path).to_s.start_with?("#{data_root}/")

    flash[:warning] = I18n.t('data_import.errors.invalid_request')
    redirect_to(push_index_path)
    false
  end

  # True only when @file_path lies in 'results.new'; files already moved to 'results.sent'
  # (or beyond) are never pushed again: flashes a warning and redirects otherwise.
  def file_path_pending?
    return true if "#{resolve_crawler_path(@file_path)}/".include?('/results.new/')

    redirect_to(push_index_path, flash: { warning: I18n.t('data_import.push.already_sent') })
    false
  end

  # Params for the redirect after an upload, keeping the listing on the pushed folder
  # (i.e. 'data/results.new/<season>').
  def upload_folder_params
    segments = resolve_crawler_path(@file_path).relative_path_from(Rails.root.join('crawler')).to_s.split('/')
    return {} if segments.size < 3

    { parent_folder: segments[1], curr_dir: segments.first(3).join('/') }
  end

  # Strong parameters checking for single file processing actions.
  def process_params
    params.permit(:file_path)
  end

  # Setter for @file_path; expects the 'file_path' parameter to be present.
  # Sets also @api_url.
  def set_file_path
    @api_url = "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    @file_path = process_params[:file_path]
    return if @file_path.present?

    flash[:warning] = I18n.t('data_import.errors.invalid_request')
    redirect_to(push_index_path)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Parses the contents of @file_path assuming it's valid JSON.
  # Sets @data_hash with the parsed contents.
  # Redirects to #pull/index in case of errors.
  def parse_file_contents
    file_content = File.read(@file_path)
    begin
      @data_hash = JSON.parse(file_content)
    rescue StandardError
      flash[:error] = I18n.t('data_import.errors.invalid_file_content')
      redirect_to(push_index_path) && return
    end
  end

  # Returns a valid Season assuming the current +@file_path+ contains the season ID as
  # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
  # Defaults to the latest MASFIN season if no valid integer was found in the last folder of the path.
  # Sets @season with the specific Season retrieved.
  def detect_season_from_pathname
    season_id = File.dirname(@file_path).split('/').last.to_i
    season_id = SeasonDefaults.default_season_id unless season_id.positive?
    @season = GogglesDb::Season.find(season_id)
  end

  # Prepares the @solver instance, assuming @file_path & @data_hash have been set.
  # Sets @solver with current Solver instance.
  def prepare_solver
    detect_season_from_pathname # (sets @season)
    # FUTUREDEV: display progress in real time using another ActionCable channel? (or same?)
    @solver = Import::MacroSolver.new(season_id: @season.id, data_hash: @data_hash, toggle_debug: true)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Assuming it's a single, valid SQL batch file, using the dedicated API endpoint,
  # this uploads <tt>file_path</tt> to the currently set remote API server.
  #
  # If successful, the file will be moved from 'results.new' to 'results.sent'.
  #
  # In case of error, flash[:error] will be non-blank.
  #
  # === Params:
  # - :file_path => path to the SQL file storing the data-import transaction.
  #
  # rubocop:disable-next Metrics/AbcSize
  def push_file_and_move(file_path)
    logger.info("\r\n---> Pushing '#{file_path}'...")
    res = APIProxy.call(
      method: :post,
      url: 'import_queue/batch_sql',
      jwt: current_user.jwt,
      payload: { data_file: File.open(file_path) }
    )
    result = JSON.parse(res.body)

    if result.respond_to?(:fetch) && result['new'].present? && result['new']['id'].to_i.positive?
      dest_file = file_path.to_s.gsub('results.new', 'results.sent')
      FileUtils.mkdir_p(File.dirname(dest_file)) # Ensure the destination path is there
      File.rename(file_path, dest_file)
      flash[:info] = I18n.t('data_import.push.msg_send_batch_ok')
      record_push_event(file_path, success: true, queue_id: result['new']['id'])
    else
      flash[:error] = result['msg']
      record_push_event(file_path, success: false, error: result['msg'])
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
