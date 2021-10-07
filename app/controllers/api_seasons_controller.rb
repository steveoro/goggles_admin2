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
      params: { page: index_params[:page], per_page: index_params[:per_page] }
    )
    @domain_count = result.headers[:total].to_i
    @domain_page = result.headers[:page].to_i
    @domain_per_page = result.headers[:per_page].to_i
    json_domain = JSON.parse(result.body)

    # Setup grid domain (and chart's):
    @domain = json_domain.map { |attrs| GogglesDb::Season.new(attrs) }

    # Setup datagrid:
    SeasonsGrid.data_domain = @domain

    respond_to do |format|
      format.html do
        @grid = SeasonsGrid.new(grid_filter_params)
      end

      format.csv do
        @grid = SeasonsGrid.new(grid_filter_params)
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-seasons-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
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
    # DEBUG
    # logger.debug("\r\n*** update PARAMS:")
    # logger.debug(edit_params(GogglesDb::Season).inspect)
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
    redirect_to api_seasons_path
  end

  # POST /api_seasons
  # Creates a new GogglesDb::Season row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    # DEBUG
    # logger.debug("\r\n*** create PARAMS:")
    # logger.debug(edit_params(GogglesDb::Season).inspect)
    result = APIProxy.call(
      method: :post,
      url: 'season',
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Season)
    )
    json = result.code == 200 && result.body.present? ? JSON.parse(result.body) : {}

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_seasons_path
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
