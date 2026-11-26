# frozen_string_literal: true

# = ImportQueues Controller
#
# Manage ImportQueues via API.
#
class APIImportQueuesController < ApplicationController
  include APIGridIndex

  # GET /api_import_queues
  # Show the ImportQueues dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    result = APIProxy.call(
      method: :get, url: 'import_queues', jwt: current_user.jwt,
      params: { page: index_params[:page], per_page: index_params[:per_page] }.merge(api_filter_params)
    )
    render_api_index(ImportQueuesGrid, GogglesDb::ImportQueue, result, csv_name: 'iq') do |domain, parsed_response|
      ImportQueuesGrid.outbox_scripts = ImportQueuesGrid.outbox_scripts_for(domain)
      ImportQueuesGrid.data_file_names = ImportQueuesGrid.data_file_names_for(parsed_response)
    end
  end

  # POST /api_import_queues
  # Creates a new GogglesDb::ImportQueue row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'import_queue',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::ImportQueue)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to(api_import_queues_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_import_queue/:id
  # Updates a single GogglesDb::ImportQueue row.
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
      url: "import_queue/#{edit_params(GogglesDb::ImportQueue)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::ImportQueue)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.presence || result.code)
    end
    redirect_to(api_import_queues_path(index_params))
  end

  # DELETE /api_import_queues
  # Removes GogglesDb::ImportQueue rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  # rubocop:disable-next Metrics/AbcSize
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('import_queue', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(api_import_queues_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:import_queues_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:import_queues_grid)
  end

  # The Yes/No filters of the grid ('done', 'batch_sql'), sent to the API (goggles_api 0.10.82 filters on both
  # true and false) so they cover every row, not only the current page. A filter not chosen is not sent.
  def api_filter_params
    %i[done batch_sql].each_with_object({}) do |name, filters|
      value = index_params[name].to_s.downcase
      filters[name] = true if Datagrid::Filters::ExtendedBooleanFilter::TRUTH_VALUES.include?(value)
      filters[name] = false if Datagrid::Filters::ExtendedBooleanFilter::FALSE_VALUES.include?(value)
    end
  end
end
