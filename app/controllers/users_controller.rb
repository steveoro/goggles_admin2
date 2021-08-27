# frozen_string_literal: true

# = UsersController
#
# Manage User via API.
#
class UsersController < ApplicationController
  # Show the Users dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    # logger.debug("\r\n*** PARAMS:")
    # logger.debug(grid_filter_params.inspect)
    domain_attributes = JSON.parse(GogglesDb::User.all.to_a.to_json)
    # @user_list = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)
    @domain = domain_attributes.map { |attrs| GogglesDb::User.new(attrs) }

    # Setup datagrid:
    UsersGrid.class_variable_set(:@@data_domain, @domain)

    respond_to do |format|
      format.html do
        @grid = UsersGrid.new(grid_filter_params) do |scope|
          Kaminari.paginate_array(scope, total_count: @domain.count).page(params[:page]).per(10)
        end
      end

      format.csv do
        @grid = UsersGrid.new(grid_filter_params)
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-users-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /users/update/:id
  # Updates a single GogglesDb::User row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - id: instance row to be updated
  #
  def update
    logger.debug("\r\n*** update PARAMS:")
    logger.debug(edit_params.inspect)

    # TODO
    # result = APIProxy.call(method: :put, url: 'user', jwt: current_user.jwt, params: edit_params)
    # (Actual result will be JSON)
    result = GogglesDb::User.update(
      edit_params['id'],
      edit_params.reject { |key, _v| key == 'id' }
    )

    if result.valid?
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: 'Validation error!')
    end
    redirect_to users_path
  end

  # POST /users/create
  # Creates a new GogglesDb::User row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    logger.debug("\r\n*** create PARAMS:")
    logger.debug(edit_params.inspect)
    # TODO
    # result = APIProxy.call(method: :post, url: 'user', jwt: current_user.jwt, params: params['id'])
    result = GogglesDb::User.create(
      edit_params.reject { |key, _v| %w[id authenticity_token].include?(key) }
    )

    if result.valid?
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: 'Validation error!')
    end
    redirect_to users_path
  end

  # DELETE /users/destroy
  # Removes GogglesDb::User rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - id: to be used for single row deletion
  # - ids: to be used for multiple rows deletion
  #
  def destroy
    # TODO
    # 1. check parameters: id => single delete; ids: comma sep. list of deletions
    # 2. make api call to delete the row
    # 3. check result & set flash + redirect
    if delete_params[:id].present?
      flash[:info] = "Deleted row: #{delete_params[:id]}"
      # TODO
      # result = APIProxy.call(method: :delete, url: 'user', jwt: current_user.jwt, params: params['id'])
      # (Actual result will be JSON)
    end

    if delete_params[:ids].present?
      row_ids = delete_params[:ids].split(',')
      flash[:info] = "Deleted rows: #{row_ids.inspect}"
      # result = APIProxy.call(method: :delete, url: 'user', jwt: current_user.jwt, params: params['id'])
      # (Actual result will be JSON)
    end
    redirect_to users_path
  end

  protected

  # Default whitelist for datagrid parameters
  def grid_filter_params
    params.fetch(:users_grid, {}).permit!
  end

  # Parameters strong-checking for grid row create/update
  def edit_params
    params.permit(
      GogglesDb::User.new
                     .attributes.keys
                     .reject { |key| %w[lock_version created_at updated_at authenticity_token].include?(key) } +
                     [:authenticity_token]
    )
  end

  # Parameters strong-checking for grid row(s) delete
  def delete_params
    params.permit(:id, :ids, :_method, :authenticity_token)
  end
end
