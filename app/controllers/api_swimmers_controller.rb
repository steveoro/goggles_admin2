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
      params: {
        name: index_params[:name], year_of_birth: index_params[:year_of_birth],
        # FIXME: current version of the API wrongly defines year_guessed as an integer!
        year_guessed: index_params[:year_guessed] == 'true' ? 1 : 0,
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    json_domain = JSON.parse(result.body)
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: json_domain['error'])
      redirect_to(root_path) && return
    end

    @domain_count = result.headers[:total].to_i
    @domain_page = result.headers[:page].to_i
    @domain_per_page = result.headers[:per_page].to_i

    # Setup grid domain (and chart's):
    @domain = json_domain.map { |attrs| GogglesDb::Swimmer.new(attrs) }

    # Setup datagrid:
    SwimmersGrid.data_domain = @domain

    respond_to do |format|
      @grid = SwimmersGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
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
    redirect_to api_swimmers_path(page: index_params[:page], per_page: index_params[:per_page])
  end

  # POST /api_swimmers
  # Creates a new GogglesDb::Swimmer row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'swimmer',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::Swimmer)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_swimmers_path(page: index_params[:page], per_page: index_params[:per_page])
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
