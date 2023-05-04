# frozen_string_literal: true

# = API Seasons Controller
#
# Manage Seasons via API.
#
class APISeasonsController < ApplicationController
  # GET /api_seasons
  # Show the Seasons dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'seasons', jwt: current_user.jwt,
      params: {
        begin_date: index_params[:begin_date], end_date: index_params[:end_date],
        header_year: index_params[:header_year],
        season_type_id: index_params[:season_type_id],
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = JSON.parse(result.body)
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(SeasonsGrid, GogglesDb::Season, result.headers, parsed_response)

    respond_to do |format|
      @grid = SeasonsGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-seasons-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_seasons
  # Creates a new GogglesDb::Season row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'season',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::Season)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_seasons_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_seasons/:id
  # Updates a single GogglesDb::Season row.
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
      url: "season/#{edit_params(GogglesDb::Season)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Season)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to api_seasons_path(page: index_params[:page], per_page: index_params[:per_page])
  end

  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:seasons_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :seasons_grid)
                          .merge(params.fetch(:seasons_grid, {}).permit!)
  end
end
