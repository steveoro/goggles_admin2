# frozen_string_literal: true

# = API TeamAffiliations Controller
#
# Manage TeamAffiliations via API.
#
class APITeamAffiliationsController < ApplicationController
  # GET /api_team_affiliations
  # Show the TeamAffiliations dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'team_affiliations', jwt: current_user.jwt,
      params: {
        season_id: index_params[:season_id], name: index_params[:name],
        compute_gogglecup: index_params[:compute_gogglecup],
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
    @domain = json_domain.map { |attrs| GogglesDb::TeamAffiliation.new(attrs) }

    # Setup datagrid:
    TeamAffiliationsGrid.data_domain = @domain

    respond_to do |format|
      format.html do
        @grid = TeamAffiliationsGrid.new(grid_filter_params)
      end

      format.csv do
        @grid = TeamAffiliationsGrid.new(grid_filter_params)
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-team_affiliations-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_team_affiliation/:id
  # Updates a single GogglesDb::TeamAffiliation row.
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
    # logger.debug(edit_params(GogglesDb::TeamAffiliation).inspect)
    result = APIProxy.call(
      method: :put,
      url: "team_affiliation/#{edit_params(GogglesDb::TeamAffiliation)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::TeamAffiliation)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to api_team_affiliations_path
  end

  # POST /api_team_affiliations
  # Creates a new GogglesDb::TeamAffiliation row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    # DEBUG
    # logger.debug("\r\n*** create PARAMS:")
    # logger.debug(edit_params(GogglesDb::TeamAffiliation).inspect)
    result = APIProxy.call(
      method: :post,
      url: 'team_affiliation',
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::TeamAffiliation)
    )
    json = result.code == 200 && result.body.present? ? JSON.parse(result.body) : {}

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to api_team_affiliations_path
  end

  # DELETE /api_team_affiliations
  # Removes GogglesDb::TeamAffiliation rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable Metrics/AbcSize
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('team_affiliation', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to api_team_affiliations_path
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:team_affiliations_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :team_affiliations_grid)
                          .merge(params.fetch(:team_affiliations_grid, {}).permit!)
  end
end
