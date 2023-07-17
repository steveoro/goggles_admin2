# frozen_string_literal: true

# = API CategoryTypes Controller
#
# Manage CategoryTypes via API.
#
class APICategoriesController < ApplicationController
  # GET /api_categories
  # Show the CategoryTypes dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'category_types', jwt: current_user.jwt,
      params: {
        season_id: index_params[:season_id],
        code: index_params[:code], relay: index_params[:relay],
        out_of_race: index_params[:out_of_race], undivided: index_params[:undivided],
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(CategoriesGrid, GogglesDb::CategoryType, result.headers, parsed_response)

    respond_to do |format|
      @grid = CategoriesGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-categories-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_categories
  # Creates a new GogglesDb::CategoryType row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'category_type',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::CategoryType)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to(api_categories_path(index_params))
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_category/:id
  # Updates a single GogglesDb::CategoryType row.
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
      url: "category_type/#{edit_params(GogglesDb::CategoryType)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::CategoryType)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to(api_categories_path(index_params))
  end

  # DELETE /category_types
  # Removes GogglesDb::CategoryType rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable Metrics/AbcSize
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('category_type', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(api_categories_path(index_params))
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # POST /api_categories/clone
  # Clones a bunch of GogglesDb::CategoryType rows, from a season to another.
  #
  # == Params:
  # - <tt>from_season</tt>, source season_id (must be already existing)
  # - <tt>to_season</tt>, target season_id (must be already existing)
  #
  # Note that the API endpoint may signal errors in case of invalid Seasons, but won't check
  # for duplicate rows.
  #
  def clone
    result = APIProxy.call(
      method: :post,
      url: 'category_types/clone',
      jwt: current_user.jwt,
      payload: clone_params
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.clone_form.clone_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.clone_form.clone_failed', error: result.code)
    end
    redirect_to(api_categories_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:categories_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:categories_grid)
  end

  # Strong parameters checking for /clone
  def clone_params
    params.permit(:from_season, :to_season)
  end
end
