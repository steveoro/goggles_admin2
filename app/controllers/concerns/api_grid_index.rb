# frozen_string_literal: true

#
# = APIGridIndex
#
# Shared end of the index action of the api_* grid controllers (phase 15). Each controller keeps its own
# <tt>APIProxy.call(...)</tt> (exact arguments: the request specs stub them) and hands the result over:
#
#   def index
#     result = APIProxy.call(method: :get, url: 'teams', jwt: current_user.jwt, params: { ... })
#     render_api_index(TeamsGrid, GogglesDb::Team, result, csv_name: 'teams')
#   end
#
# - code 200: the grid domain is set from the answer (#set_grid_domain_for), the optional block gets the domain
#   rows and the parsed answer (extra class attributes of the grid), then the HTML page or the CSV export is sent.
#   The CSV header row is always the English one (stable for the spreadsheets built on it).
# - any other code (unreachable API included): the same page is rendered with status 200 and the API error box
#   (Grid::APIErrorComponent: code, error detail, Retry link) in place of the rows, the filters still usable;
#   a CSV request is redirected to the page. Nothing bounces to the dashboard any more.
#
# The views read everything through the <tt>api_grid_domain</tt> helper (see Grid::PageComponent).
#
module APIGridIndex
  extend ActiveSupport::Concern

  # Locale of the CSV header row.
  CSV_LOCALE = :en

  included do
    helper_method :api_grid_domain
  end

  protected

  # Renders the index page (or the CSV export) of an API grid.
  #
  # == Params:
  # - grid_class, model_class: the Datagrid class and the GogglesDb model of the rows;
  # - result: the APIProxy::Result (or a response double) of the index call;
  # - csv_name: the CSV file name part ('grid-<csv_name>-<timestamp>.csv');
  # - grid_params: the attributes of the grid instance (default: the controller's #grid_filter_params);
  # - csv_columns: the CSV columns (default: all the columns).
  def render_api_index(grid_class, model_class, result, csv_name:, grid_params: nil, csv_columns: []) # rubocop:disable Metrics/ParameterLists
    if result.code == 200
      parsed_response = result.body.present? ? JSON.parse(result.body) : []
      set_grid_domain_for(grid_class, model_class, result.headers, parsed_response)
      yield(@domain, parsed_response) if block_given?
    else
      grid_class.data_domain = []
      @api_error = Grid::APIErrorComponent.error_for(result)
    end
    @grid = grid_class.new(grid_params || grid_filter_params)

    respond_to do |format|
      format.html { @grid }
      format.csv { @api_error ? redirect_to(api_index_html_path) : send_grid_csv(csv_name, csv_columns) }
    end
  end

  # Renders the current action's page with status 200 and the API error box (for the bespoke pages without a
  # grid, e.g. trainings). +assigns+: instance variables the template still reads (e.g. <tt>rows: []</tt>).
  def render_api_error(result, **assigns)
    @api_error = Grid::APIErrorComponent.error_for(result)
    assigns.each { |name, value| instance_variable_set(:"@#{name}", value) }
    render(action_name)
  end

  # What the API index call gave (read by Grid::PageComponent): row counters, rows, the grid and index params, and
  # the API error (a Grid::APIErrorComponent::Error, nil after a 200).
  def api_grid_domain
    {
      count: @domain_count, page: @domain_page, per_page: @domain_per_page, rows: @domain,
      filter_params: @grid_filter_params, index_params: @index_params, error: @api_error
    }
  end

  private

  def send_grid_csv(csv_name, csv_columns)
    send_data(
      I18n.with_locale(CSV_LOCALE) { @grid.to_csv(*csv_columns) },
      type: 'text/csv',
      disposition: 'inline',
      filename: "grid-#{csv_name}-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
    )
  end

  # The HTML index page with the same query (for a CSV request answered by an API error).
  def api_index_html_path
    url_for(controller: controller_name, action: :index, params: request.query_parameters, format: nil, only_path: true)
  end
end
