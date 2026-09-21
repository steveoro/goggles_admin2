# frozen_string_literal: true

# = TeamManagers Controller
#
# Manage Team Managers (GogglesDb::ManagedAffiliation) via API.
#
class APITeamManagersController < ApplicationController
  # GET /api_team_managers
  # Show the ManagedAffiliations dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'team_managers', jwt: current_user.jwt,
      params: {
        team_affiliation_id: index_params[:team_affiliation_id],
        manager_name: index_params[:manager_name],
        team_name: index_params[:team_name],
        season_id: index_params[:season_id],
        season_description: index_params[:season_description],
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(TeamManagersGrid, GogglesDb::ManagedAffiliation, result.headers, parsed_response)
    @grid = TeamManagersGrid.new(grid_filter_params) # { @domain }

    respond_to do |format|
      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-team_managers-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_team_managers
  # Creates a new GogglesDb::ManagedAffiliation row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'team_manager',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::ManagedAffiliation)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to(api_team_managers_path(index_params))
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_team_manager/:id
  # Updates a single GogglesDb::ManagedAffiliation row.
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
      url: "team_manager/#{edit_params(GogglesDb::ManagedAffiliation)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::ManagedAffiliation)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to(api_team_managers_path(index_params))
  end

  # DELETE /api_team_managers
  # Removes GogglesDb::ManagedAffiliation rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable-next Metrics/AbcSize
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('team_manager', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(api_team_managers_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # POST /api_team_managers/sql_create
  # Creates the managed_affiliations row (and the team_affiliations row, when missing)
  # directly on the *localhost* DB, generating also a replayable single-transaction
  # SQL batch file under <tt>crawler/data/results.new/<season_id>/</tt> for the
  # push-to-remote pipeline.
  #
  # Feasibility is checked against the localhost DB (assumed in-sync with production):
  # the action fails when any of the 3 entities is missing or when the resulting
  # (team_affiliation_id, user_id) ManagedAffiliation already exists.
  #
  # == Params (namespaced under 'sql-create'):
  # - <tt>season_id</tt>: Season row ID
  # - <tt>team_id</tt>: Team row ID
  # - <tt>user_id</tt>: User (manager) row ID
  #
  def sql_create
    creator = TeamManagerSqlCreate.new(
      season_id: sql_create_params[:season_id],
      team_id: sql_create_params[:team_id],
      user_id: sql_create_params[:user_id]
    )

    if creator.call
      flash[:info] = I18n.t('datagrid.sql_create.create_ok', file: File.basename(creator.file_path.to_s))
    else
      flash[:error] = I18n.t('datagrid.sql_create.create_failed', error: creator.errors.join(', '))
    end
    redirect_to(api_team_managers_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:team_managers_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:team_managers_grid)
  end

  # Strong parameters checking for /sql_create.
  # (Field names are namespaced under 'sql-create' to avoid clashes with the
  # flat-named fields of the generic edit modal on the same page.)
  def sql_create_params
    params.fetch(:'sql-create', ActionController::Parameters.new)
          .permit(:season_id, :team_id, :user_id)
  end
end
