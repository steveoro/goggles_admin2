# frozen_string_literal: true

# = PushController: data-import pre-production "push" dashboard
#
# Recap & show pending data-import data before the final push to production.
# (Legacy data-import step 2 & 3)
#
class PushController < FileListController
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
  # === Requires:
  # - @file_path, containing the JSON data
  # - @data_hash, parsed data from @file_path
  # - @season, correct Season
  # - @solver, uses @data_hash & @season
  #
  def prepare
    # Prepare the SQL batch file logging each statement:
    @committer = Import::MacroCommitter.new(solver: @solver)
    @committer.commit_all

    # Save the batch file:
    batch_sql_path = @file_path.gsub('.json', '.sql')
    File.open(batch_sql_path, 'w+') do |f|
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
  # Allows single batch file push.
  # "Consumes" the local batch file afterwards by moving it to either to the 'sent' or 'done' folder
  # depending if this is the first upload or the sencond. (The target folder includes the season code as subfolder).
  #
  # Having 3 steps until "done" allows us a double results upload: 1° staging, 2° production.
  # (Currently, a manual configuration change is required in between.)
  #
  # === Requires:
  # - @file_path, containing the SQL batch file to be sent.
  #
  def upload
    res = APIProxy.call(
      method: :post,
      url: 'import_queue/batch_sql',
      jwt: current_user.jwt,
      payload: { data_file: File.open(@file_path) }
    )
    result = JSON.parse(res.body)

    if result.respond_to?(:fetch) && result['new'].present? && result['new']['id'].to_i.positive?
      # Move strategy: 'results.new/*' => 'results.sent/*' => 'results.done/*'
      from_folder, to_folder = @file_path.include?('results.new') ? %w[results.new results.sent] :
                                                                    %w[results.sent results.done]
      dest_file = @file_path.gsub(from_folder, to_folder)
      FileUtils.mkdir_p(File.dirname(dest_file)) # Make sure the destination path is there
      File.rename(@file_path, dest_file)
      flash[:info] = I18n.t('data_import.push.msg_send_batch_ok')
    else
      flash[:error] = result['msg']
    end

    redirect_to(push_index_path)
  end
  #-- -------------------------------------------------------------------------
  #++

  private

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

  # Returns a valid Season assuming the specified +pathname+ contains the season ID as
  # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
  # Defaults to season ID 212 if no valid integer was found in the last folder of the path.
  # Sets @season with the specific Season retrieved.
  def detect_season_from_pathname(pathname)
    season_id = File.dirname(@file_path).split('/').last.to_i
    season_id = 212 unless season_id.positive?
    @season = GogglesDb::Season.find(season_id)
  end

  # Prepares the @solver instance, assuming @file_path & @data_hash have been set.
  # Sets @solver with current Solver instance.
  def prepare_solver
    detect_season_from_pathname(@file_path) # (sets @season)
    # FUTUREDEV: display progress in real time using another ActionCable channel? (or same?)
    @solver = Import::MacroSolver.new(season_id: @season.id, data_hash: @data_hash, toggle_debug: true)
  end
  #-- -------------------------------------------------------------------------
  #++
end
