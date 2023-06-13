# frozen_string_literal: true

# = StandardTimings Controller
#
# Manage Standard (Base) Timings via API.
#
class APIStandardTimingsController < ApplicationController
  # GET /api_standard_timings
  # Show the StandardTimings dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'standard_timings', jwt: current_user.jwt,
      params: {
        season_id: index_params[:season_id],
        gender_type_id: index_params[:gender_type_id],
        pool_type_id: index_params[:pool_type_id],
        event_type_id: index_params[:event_type_id],
        category_type_id: index_params[:category_type_id],
        page: index_params[:page], per_page: index_params[:per_page] || 25
      }
    )
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(StandardTimingsGrid, GogglesDb::StandardTiming, result.headers, parsed_response)

    respond_to do |format|
      @grid = StandardTimingsGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-timings-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_standard_timings
  # Creates a new GogglesDb::StandardTiming row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'standard_timing',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::StandardTiming)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_standard_timings_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_standard_timing/:id
  # Updates a single GogglesDb::StandardTiming row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be updated
  #
  def update
    result = APIProxy.call(
      method: :put,
      url: "standard_timing/#{edit_params(GogglesDb::StandardTiming)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::StandardTiming)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to api_standard_timings_path(page: index_params[:page], per_page: index_params[:per_page])
  end

  # DELETE /api_standard_timings
  # Removes GogglesDb::StandardTiming rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable Metrics/AbcSize
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('standard_timing', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to api_standard_timings_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:standard_timings_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :standard_timings_grid)
                          .merge(params.fetch(:standard_timings_grid, {}).permit!)
  end
end
