# frozen_string_literal: true

# = API SwimmingPools Controller
#
# Manage SwimmingPools via API.
#
class APISwimmingPoolsController < ApplicationController
  # GET /api_swimming_pools
  # Show the SwimmingPools dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'swimming_pools', jwt: current_user.jwt,
      params: {
        name: index_params[:name], address: index_params[:address],
        pool_type_id: index_params[:pool_type_id], city_id: index_params[:city_id],
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = JSON.parse(result.body)
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(SwimmingPoolsGrid, GogglesDb::SwimmingPool, result.headers, parsed_response)

    respond_to do |format|
      @grid = SwimmingPoolsGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-swimming_pools-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_swimming_pools
  # Creates a new GogglesDb::SwimmingPool row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'swimming_pool',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::SwimmingPool)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_swimming_pools_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_swimming_pool/:id
  # Updates a single GogglesDb::SwimmingPool row.
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
      url: "swimming_pool/#{edit_params(GogglesDb::SwimmingPool)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::SwimmingPool)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to api_swimming_pools_path(page: index_params[:page], per_page: index_params[:per_page])
  end

  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:swimming_pools_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :swimming_pools_grid)
                          .merge(params.fetch(:swimming_pools_grid, {}).permit!)
  end
end
