# frozen_string_literal: true

# = StatsController
#
# Manage Stats via API.
#
class StatsController < ApplicationController
  # Show the dashboard concerning API daily uses
  def index
    api_use_attributes = JSON.parse(GogglesDb::APIDailyUse.all.to_a.to_json)
    # @user_list = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)

    # #<GogglesDb::APIDailyUse:0x00007fcf11205930> {
    #               :id => 1,
    #           :route => "REQ-127.0.0.1",
    #             :day => Wed, 04 Aug 2021,
    #           :count => 10 # ...
    # }

    # Prepare a list of records for a better handling and extract the unique set of days too:
    @api_uses = api_use_attributes.map { |attrs| GogglesDb::APIDailyUse.new(attrs) }
    day_keys = @api_uses.map{ |row | row.day.to_s }.uniq
    url_keys = @api_uses.map(&:route).uniq

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
    @api_uses.each do |row|
      @day_hash[row.day.to_s].x_values << row.route
      @day_hash[row.day.to_s].y_values << row.count

      @url_hash[row.route].x_values << row.day.to_s
      @url_hash[row.route].y_values << row.count
    end

    # Results:
    # - @api_uses: list of all the rows
    # - @day_hash: overall daily uses for all routes
    # - @url_hash: daily uses for each route, a different line for each key

    # Setup datagrid:

    # grid_class = Class.new(StatsGrid) do
    #   scope { @api_uses }
    # end
    # @grid = grid_class.new(grid_params)

    StatsGrid.class_variable_set(:@@data_domain, @api_uses)
    @grid = StatsGrid.new(grid_params) do |scope|
      Kaminari.paginate_array(scope).page(params[:page]).per(10)
    end
  end

  def destroy
    # TODO
    flash[:info] = 'WORK IN PROGRESS!'
    redirect_to stats_path
  end

  protected

  # Default whitelist for datagrid parameters
  def grid_params
    params.fetch(:stats_grid, {}).permit!
  end

  private

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
