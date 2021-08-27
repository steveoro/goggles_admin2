# frozen_string_literal: true

# = StatsController
#
# Manage Stats via API.
#
class StatsController < ApplicationController
  # Show the API daily uses dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  # - <tt>@day_hash</tt>: overall daily uses for all routes (group keys used to draw chart)
  # - <tt>@url_hash</tt>: daily uses for each route, a different line for each key (group keys used to draw chart)
  #
  def index
    # logger.debug("\r\n*** PARAMS:")
    # logger.debug(grid_filter_params.inspect)
    domain_attributes = JSON.parse(GogglesDb::APIDailyUse.all.to_a.to_json)
    # @user_list = APIProxy.call(method: :get, url: 'api_daily_use', jwt: current_user.jwt)

    # Prepare a list of records for better handling:
    @domain = domain_attributes.map { |attrs| GogglesDb::APIDailyUse.new(attrs) }
    day_keys = @domain.map { |row| row.day.to_s }.uniq
    url_keys = @domain.map(&:route).uniq

    # Day & URL hash init: empty overall counters for each key date / URL
    @day_hash = {}
    @url_hash = {}
    day_keys.each { |day| @day_hash[day] = DataPoint.new(uid: day) }
    url_keys.each { |url| @url_hash[url] = DataPoint.new(uid: url) }

    # Group by:
    # - @day_hash => each unique day: collect counters (Y) & associated routes (unused)
    #             => each key will become an X point in the overall line chart
    #
    # - @url_hash => each unique route: collect date (X) & counter (Y)
    #             => each key will become a different line, using the above axes
    @domain.each do |row|
      @day_hash[row.day.to_s].x_values << row.route
      @day_hash[row.day.to_s].y_values << row.count

      @url_hash[row.route].x_values << row.day.to_s
      @url_hash[row.route].y_values << row.count
    end

    # Setup datagrid:
    StatsGrid.class_variable_set(:@@data_domain, @domain)

    respond_to do |format|
      format.html do
        @grid = StatsGrid.new(grid_filter_params) do |scope|
          Kaminari.paginate_array(scope, total_count: @domain.count).page(params[:page]).per(10)
        end
      end

      format.csv do
        @grid = StatsGrid.new(grid_filter_params)
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-stats-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /stats/update/:id
  # Updates a single GogglesDb::APIDailyUse row.
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
    # result = APIProxy.call(method: :put, url: 'api_daily_use', jwt: current_user.jwt, params: edit_params)
    # (Actual result will be JSON)
    result = GogglesDb::APIDailyUse.update(
      edit_params['id'],
      edit_params.reject { |key, _v| key == 'id' }
    )

    if result.valid?
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: 'Validation error!')
    end
    redirect_to stats_path
  end

  # POST /stats/create
  # Creates a new GogglesDb::APIDailyUse row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    logger.debug("\r\n*** create PARAMS:")
    logger.debug(edit_params.inspect)
    flash[:info] = 'WORK IN PROGRESS!'
    # TODO
    # 1. check parameters: id => single delete; ids: comma sep. list of deletions
    # 2. make api call to delete the row
    # 3. check result & set flash + redirect
    # result = APIProxy.call(method: :post, url: 'api_daily_use', jwt: current_user.jwt, params: params['id'])
    redirect_to stats_path
  end

  # DELETE /stats/destroy
  # Removes GogglesDb::APIDailyUse rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
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
      # result = APIProxy.call(method: :delete, url: 'api_daily_use', jwt: current_user.jwt, params: params['id'])
      # (Actual result will be JSON)
    end

    if delete_params[:ids].present?
      row_ids = delete_params[:ids].split(',')
      flash[:info] = "Deleted rows: #{row_ids.inspect}"
      # result = APIProxy.call(method: :delete, url: 'api_daily_use', jwt: current_user.jwt, params: params['id'])
      # (Actual result will be JSON)
    end
    redirect_to stats_path
  end

  protected

  # Default whitelist for datagrid parameters
  def grid_filter_params
    params.fetch(:stats_grid, {}).permit!
  end

  # Parameters strong-checking for grid row create/update
  def edit_params
    params.permit(
      GogglesDb::APIDailyUse.new
                            .attributes.keys
                            .reject { |key| %w[lock_version created_at updated_at].include?(key) } +
                            [:authenticity_token]
    )
  end

  # Parameters strong-checking for grid row(s) delete
  def delete_params
    params.permit(:id, :ids, :_method, :authenticity_token)
  end

  #
  # Internal class used to represent a point on a line chart
  #
  class DataPoint
    attr_accessor :uid, :x_values, :y_values

    # Creates a new DataPoint instance
    def initialize(uid:, x_values: [], y_values: [])
      @uid = uid
      @x_values = x_values
      @y_values = y_values
    end

    # Helper to render the values as 3 point coordinates in Chart.js-compliant mode
    def to_json_bubble_chart_data
      coords = []
      x_values.each_with_index { |x, idx| coords << { 'x' => x, 'y' => y_values[idx], 'r' => y_values[idx] } }
      {
        'type' => 'bubble',
        'label' => uid,
        'data' => coords
      }
    end
  end
end
