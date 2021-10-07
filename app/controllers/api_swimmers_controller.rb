# frozen_string_literal: true

# = API Swimmers Controller
#
# Manage Swimmers via API.
#
class APISwimmersController < ApplicationController
  # GET /api_swimmers
  # Show the Swimmers dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'swimmers', jwt: current_user.jwt,
      params: { page: index_params[:page], per_page: index_params[:per_page] }
    )
    @domain_count = result.headers[:total].to_i
    @domain_page = result.headers[:page].to_i
    @domain_per_page = result.headers[:per_page].to_i
    json_domain = JSON.parse(result.body)

    # Setup grid domain (and chart's):
    @domain = json_domain.map { |attrs| GogglesDb::Swimmer.new(attrs) }

    # Setup datagrid:
    SwimmersGrid.data_domain = @domain

    respond_to do |format|
      format.html do
        @grid = SwimmersGrid.new(grid_filter_params)
      end

      format.csv do
        @grid = SwimmersGrid.new(grid_filter_params)
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-swimmers-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_swimmer/:id
  # Updates a single GogglesDb::Swimmer row.
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
    # logger.debug(edit_params(GogglesDb::Swimmer).inspect)
    result = APIProxy.call(
      method: :put,
      url: "swimmer/#{edit_params(GogglesDb::Swimmer)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Swimmer)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to api_swimmers_path
  end

  # POST /api_swimmers
  # Creates a new GogglesDb::Swimmer row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    # DEBUG
    # logger.debug("\r\n*** create PARAMS:")
    # logger.debug(edit_params(GogglesDb::Swimmer).inspect)
    result = APIProxy.call(
      method: :post,
      url: 'swimmer',
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Swimmer)
    )
    json = result.code == 200 && result.body.present? ? JSON.parse(result.body) : {}

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_swimmers_path
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:swimmers_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :swimmers_grid)
                          .merge(params.fetch(:swimmers_grid, {}).permit!)
  end
end
