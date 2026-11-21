# frozen_string_literal: true

# = PushController: data-import pre-production "push" dashboard
#
# Recap & show pending data-import data before the final push to production.
# (Final data-import step: SQL batch upload to the API)
#
class PushController < FileListController
  include PushEventRecorder

  # Member @file_path must be set for all actions except the index (redirects when missing)
  before_action :set_file_path, except: :index

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
