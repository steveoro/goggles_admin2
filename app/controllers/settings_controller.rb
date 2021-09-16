# frozen_string_literal: true

# = SettingsController
#
# Manage Settings via API.
#
class SettingsController < ApplicationController
  # Show the Settings dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    # Get the local API URL for reaching the remote server:
    @connection_url = GogglesDb::AppParameter.config.settings(:framework_urls).value['api']
    @connection_status = prepare_status_label

    # Prepare remote domain:
    setting_groups = GogglesDb::AppParameter::SETTINGS_GROUPS + [:prefs]
    @domain = []
    @domain_count = @domain_page = @domain_per_page = 0

    setting_groups.each do |group_key|
      result = APIProxy.call(method: :get, url: "setting/#{group_key}", jwt: current_user.jwt)
      json_domain = result.code == 200 && result.body.present? ? JSON.parse(result.body) : {}
      # NOTE: the API result, in this case is a map of keys & values for the specified group key
      # Flattening the group hash of keys into a single domain:
      group_array = json_domain.map do |key, value|
        Setting.new(group_key: group_key, key: key, value: value)
      end
      @domain += group_array
      @domain_count += group_array.count
    end

    # Setup datagrid:
    SettingsGrid.data_domain = @domain

    respond_to do |format|
      format.html do
        @grid = SettingsGrid.new(grid_filter_params)
      end

      format.csv do
        @grid = SettingsGrid.new(grid_filter_params)
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

  # PUT /settings/update/:id
  # Updates a single Setting row.
  #
  # Supported attributes: <tt>group_key</tt>, <tt>key</tt> & <tt>value</tt>.
  #
  # == Route param:
  # - <tt>group_key</tt>: the Group ID for the settings key that has to be updated
  #
  def update
    # DEBUG
    # logger.debug("\r\n*** update PARAMS:")
    # logger.debug(edit_params(Setting).inspect)
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
    redirect_to settings_path
  end

  # DELETE /settings/destroy
  # Removes settings rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!(Setting, row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to settings_path
  end
  #-- -------------------------------------------------------------------------
  #++

  # POST /settings/api_config
  # Updates the current, local connection URL by writing the parameters to the local settings
  # table.
  #
  # (This allows us to connect to different servers while running the same Admin application.)
  #
  # == Params:
  # - <tt>connect_to</tt>: the full URI of the API server to which we need to connect.
  #
  def api_config
    redirect_to root_path && return unless request.post?

    connect_to = params.permit(:connect_to)['connect_to']
    if connect_to.present?
      cfg = GogglesDb::AppParameter.config
      cfg.settings(:framework_urls).value['api'] = connect_to
      if cfg.save
        sign_out(current_user)
      else
        flash[:error] = I18n.t('dashboard.settings.connection.save_failed')
      end
    else
      flash[:error] = I18n.t('dashboard.generic_param_miss_error')
    end

    redirect_to(url_for(controller: controller_name, action: :index)) && return
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:settings_grid, {}).permit!
  end

  private

  # Returns a String label summarizing the currently connected API status.
  def prepare_status_label
    result = APIProxy.call(method: :get, url: 'status', jwt: current_user.jwt)
    result_hash = result.body.present? ? JSON.parse(result.body) : {}
    "API v. #{result_hash['version']} - #{result_hash['msg']}"
  end
end
