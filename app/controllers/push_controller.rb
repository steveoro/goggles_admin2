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
  def prepare
    # Prepare the SQL batch file logging each statement:
    @committer = Import::MacroCommitter.new(solver: @solver)
    @committer.commit_all

    curr_dir = File.dirname(@file_path)
    sent_dir = curr_dir.gsub('results.new', 'results.sent')
    dest_file = File.basename(@file_path)
    done_pathname = @file_path.gsub('results.new', 'results.done') # JSON backup copy (before IDs)

    # Prepare a sequential counter prefix for the uploadable batch file:
    sql_files_count = Dir.glob(Rails.root.join('crawler', curr_dir, '**', '*.sql')).count +
                      Dir.glob(Rails.root.join('crawler', sent_dir, '**', '*.sql')).count
    dest_file = "#{format('%03d', sql_files_count + 1)}-#{File.basename(dest_file.gsub('.json', '.sql'))}"

    # Move last phase's JSON file (before IDs were set) into 'done' as a backup:
    File.rename(@file_path, done_pathname)
    # Save also the committed data to another file (storing the resulting actual IDs):
    File.open(done_pathname.gsub('.json', '.committed.json'), 'w+') { |f| f.write(@solver.data.to_json) }

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
  # Allows single batch file push.
  # "Consumes" the local batch file afterwards by moving it to either to the 'sent' or 'done' folder
  # depending if this is the first upload or the sencond. (The target folder includes the season code as subfolder).
  #
  # Having 3 steps until "done" allows us a double results upload: 1° staging, 2° production.
  # (Currently, a manual configuration change is required in between.)
  #
  # === Params:
  # - :file_path => path to the SQL file storing the data-import transaction.
  #
  # === Requires:
  # See before actions for these:
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
      # Move strategy to allow testing data-import on localhost first:
      # 1. 'results.new/*'
      #    2. => 'results.sent/*'
      #        3. => 'results.done/*'
      from_folder, to_folder = if @file_path.include?('results.new')
                                 %w[results.new results.sent]
                               else
                                 %w[results.sent results.done]
                               end
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

  # Returns a valid Season assuming the current +@file_path+ contains the season ID as
  # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
  # Defaults to season ID 212 if no valid integer was found in the last folder of the path.
  # Sets @season with the specific Season retrieved.
  def detect_season_from_pathname
    season_id = File.dirname(@file_path).split('/').last.to_i
    season_id = 212 unless season_id.positive?
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
end
