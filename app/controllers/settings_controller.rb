# frozen_string_literal: true

# = SettingsController
#
# Manage Settings via API.
#
class SettingsController < ApplicationController
  before_action :refuse_when_api_offline, only: %i[update destroy]

  # GET /settings
  # Show the Settings dashboard.
  #
  # The settings are retrieved from the remote API server currently connected; when the API is
  # unreachable or the session is "API-offline" (see APISession), the values stored in the
  # local DB are shown instead, in read-only mode.
  #
  # == Assigns:
  # - <tt>@connection_url</tt>: currently configured API base URL (local settings)
  # - <tt>@connection_status</tt>: status label for the connected API server
  # - <tt>@remote</tt>: true when the domain comes from the remote API
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    # Get the local API URL for reaching the remote server:
    @connection_url = APIProxy.configured_base_url
    @connection_status = prepare_status_label

    @domain = remote_settings_domain unless api_offline_session?
    @remote = !@domain.nil?
    @domain ||= Setting.local_domain(current_user)
    @domain_count = @domain.count
    @domain_page = @domain_per_page = 0

    # Setup datagrid:
    grid_class = @remote ? SettingsGrid : LocalSettingsGrid
    grid_class.data_domain = @domain

    respond_to do |format|
      @grid = grid_class.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-iq-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # PUT /setting/:id
  # Updates a single Setting row.
  #
  # Supported attributes: <tt>group_key</tt>, <tt>key</tt> & <tt>value</tt>.
  #
  # == Route param:
  # - <tt>ID</tt>: the composed Setting Group+Key ID for identifying uniquely the Setting that has to be updated
  #
  # == Params:
  # - <tt>group_key</tt>: Setting group ID
  # - <tt>key</tt>: Setting key ID
  #
  def update
    result = APIProxy.call(
      method: :put,
      url: "setting/#{edit_params(Setting)['group_key']}",
      jwt: current_user.jwt,
      payload: edit_params(Setting)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to(settings_path(index_params))
  end

  # DELETE /settings
  # Removes settings rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = []
    row_ids.each do |row_id|
      group_id, key_id = row_id.split(Setting::SPLIT_ID_CHAR)
      result = APIProxy.call(
        method: :delete,
        url: "setting/#{group_id}",
        jwt: current_user.jwt,
        payload: { key: key_id }
      )

      next unless result.code != 200 || result.body != 'true'

      logger.error("\r\n*** ERROR: API 'DELETE /setting/#{group_id}' (key: #{key_id})")
      logger.error(result.inspect)
      error_ids << row_id
    end

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(settings_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # POST /settings/api_config
  # Updates the current, local connection URL by writing the parameters to the local settings
  # table, then probes the new URL and signs out the current user (so that the next sign-in
  # gets a fresh JWT from the newly connected server).
  #
  # (This allows us to connect to different servers while running the same Admin application.)
  #
  # == Params:
  # - <tt>connect_to</tt>: the full URI of the API server to which we need to connect.
  #
  def api_config
    connect_to = params.permit(:connect_to)['connect_to'].to_s.strip.delete_suffix('/')
    if connect_to.blank?
      flash[:error] = I18n.t('dashboard.generic_param_miss_error')
      return redirect_to(settings_path)
    end

    cfg = GogglesDb::AppParameter.config
    cfg.settings(:framework_urls).value['api'] = connect_to
    unless cfg.save
      flash[:error] = I18n.t('dashboard.settings.connection.save_failed')
      return redirect_to(settings_path)
    end

    flash_probe_result(connect_to)
    session.delete(:api_offline)
    sign_out(current_user)
    # (Go straight to the sign-in page: an intermediate redirect would discard the probe message)
    redirect_to(new_user_session_path)
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:settings_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:settings_grid)
  end

  # The whole Settings page is reachable from API-offline sessions
  # (the remote-only actions refuse to proceed by themselves).
  def api_offline_allowed?
    true
  end

  private

  # Refuses remote-only actions for API-offline sessions.
  def refuse_when_api_offline
    return unless api_offline_session?

    flash[:error] = I18n.t('api_offline.read_only')
    redirect_to(settings_path)
  end

  # Returns a String label summarizing the currently connected API status.
  def prepare_status_label
    result = APIProxy.ping
    return "⚠ #{result.error_detail}" unless result.code == 200 && result.json.is_a?(Hash)

    "API v. #{result.json['version']} - #{result.json['msg']}"
  end

  # Sets a flash message describing the result of a status check on the specified API base URL.
  def flash_probe_result(base_url)
    result = APIProxy.ping(base_url)
    if result.code == 200
      flash[:info] = I18n.t('api_offline.probe_ok', url: base_url, version: result.json['version'])
    else
      flash[:warning] = I18n.t('api_offline.probe_failed', url: base_url, reason: result.error_detail)
    end
  end

  # Returns the list of Setting rows retrieved from the remote API;
  # +nil+ when the API server is unreachable.
  def remote_settings_domain
    (GogglesDb::AppParameter::SETTINGS_GROUPS + [:prefs]).flat_map do |group_key|
      result = APIProxy.call(method: :get, url: "setting/#{group_key}", jwt: current_user.jwt)
      return nil if result.unreachable?

      # NOTE: the API result, in this case is a map of keys & values for the specified group key
      # Flattening the group hash of keys into a single domain:
      json_domain = result.code == 200 && result.json.is_a?(Hash) ? result.json : {}
      json_domain.map { |key, value| Setting.new(group_key:, key:, value:) }
    end
  end
end
