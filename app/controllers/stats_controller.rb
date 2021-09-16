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
  # rubocop:disable Metrics/AbcSize
  def index
    # DEBUG
    # logger.debug("\r\n*** /index PARAMS:")
    # logger.debug(grid_filter_params.inspect)
    result = APIProxy.call(
      method: :get, url: 'api_daily_uses', jwt: current_user.jwt,
      params: { page: index_params[:page], per_page: index_params[:per_page] }
    )
    @domain_count = result.headers[:total].to_i
    @domain_page = result.headers[:page].to_i
    @domain_per_page = result.headers[:per_page].to_i
    json_domain = JSON.parse(result.body)

    # Setup grid domain (and chart's):
    @domain = json_domain.map { |attrs| GogglesDb::APIDailyUse.new(attrs) }
    prepare_chart_domain(@domain)

    # Setup datagrid:
    StatsGrid.data_domain = @domain

    respond_to do |format|
      format.html do
        @grid = StatsGrid.new(grid_filter_params)
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
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /stats/update/:id
  # Updates a single GogglesDb::APIDailyUse row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be updated
  #
  def update
    # DEBUG
    # logger.debug("\r\n*** /update PARAMS:")
    # logger.debug(edit_params(GogglesDb::APIDailyUse).inspect)
    result = APIProxy.call(
      method: :put,
      url: "api_daily_use/#{edit_params(GogglesDb::APIDailyUse)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::APIDailyUse)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to stats_path
  end

  # DELETE /stats/destroy
  # Removes GogglesDb::APIDailyUse rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: to be used for single row deletion
  # - <tt>ids</tt>: to be used for multiple rows deletion
  #
  # rubocop:disable Metrics/AbcSize
  def destroy
    # DEBUG
    # logger.debug("\r\n*** /destroy PARAMS:")
    # logger.debug(delete_params.inspect)
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!(GogglesDb::APIDailyUse, row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to stats_path
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid filtering parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:stats_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :stats_grid)
                          .merge(params.fetch(:stats_grid, {}).permit!)
  end

  #
  # Internal class used to represent a point on a line/bubble chart
  #
  # - x axis: x-series value
  # - y axis: counter/total value
  # - z/bubble radius: counter total divided by limiting constant (limit should be adjusted depending on avg users)
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
      x_values.each_with_index { |x, idx| coords << { 'x' => x, 'y' => y_values[idx], 'r' => y_values[idx] / 10.0 } }
      {
        'type' => 'bubble',
        'label' => uid,
        'data' => coords
      }
    end
  end

  private

  # Set the internal  data groupings used to plot the API usage chart.
  #
  # == Assigns:
  # - <tt>domain</tt>: Array of model instances.
  #
  # == Returns / Assigns the following:
  # - <tt>@day_hash</tt>: overall daily uses for all routes (group keys used to draw chart)
  # - <tt>@url_hash</tt>: daily uses for each route, a different line for each key (group keys used to draw chart)
  #
  # rubocop:disable Metrics/AbcSize
  def prepare_chart_domain(domain)
    # Prepare a list of records for better handling:
    day_keys = domain.map { |row| row.day.to_s }.uniq
    url_keys = domain.map(&:route).uniq

    # Day & URL hash init: empty overall counters for each key date / URL
    @day_hash = {}
    @url_hash = {}
    day_keys.each { |day| @day_hash[day] = DataPoint.new(uid: day) }
    url_keys.each { |url| @url_hash[url] = DataPoint.new(uid: url) }

    # User REQ hash init:
    @users_hash = {}
    day_keys.each do |day|
      req_rows = domain.select { |row| row.route =~ /REQ-/i && row.day.to_s == day }
      @users_hash[day] = DataPoint.new(
        uid: day,
        x_values: req_rows.sum(&:count), # computes total requests for the day
        y_values: req_rows.count # computes total number of different IP REQ for the day
        # (In this case ^^, we'll use just a single value, not an array)
      )
    end

    # Group by:
    # - @day_hash => each unique day: collect counters (Y) & associated routes (unused)
    #             => each key will become an X point in the overall line chart
    #
    # - @url_hash => each unique route: collect date (X) & counter (Y)
    #             => each key will become a different line, using the above axes
    domain.each do |row|
      @day_hash[row.day.to_s].x_values << row.route
      @day_hash[row.day.to_s].y_values << row.count

      @url_hash[row.route].x_values << row.day.to_s
      @url_hash[row.route].y_values << row.count
    end
  end
  # rubocop:enable Metrics/AbcSize
end
