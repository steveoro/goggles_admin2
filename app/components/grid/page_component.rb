# frozen_string_literal: true

module Grid
  #
  # = Grid::PageComponent
  #
  # The chrome shared by the api_* grid pages (phase 15): Shell::PageHeaderComponent (title + row count), the row
  # edit modal, the grid toolbar, the Datagrid filter form, the active filter labels, then either the paginated
  # Datagrid table or, after an API error, the Grid::APIErrorComponent box (the filters stay usable).
  #
  # Pages with a bespoke body keep it as the block content: with a grid it is rendered between the filter labels and
  # the table (e.g. the categories clone panel); without a grid (+grid: nil+, e.g. trainings) it is the body, replaced
  # by the error box after an API error.
  #
  # == Usage (HAML):
  #   = render(Grid::PageComponent.new(title: t('dashboard.teams.title'), model: GogglesDb::Team, grid: @grid,
  #                                    domain: api_grid_domain, toolbar: { destroy: false }))
  #
  #   = render(Grid::PageComponent.new(...)) do |page|
  #     - page.with_toolbar_extra do
  #       .btn-group= link_to(...)
  #
  # == Slots:
  # - toolbar_extra: more buttons at the end of the grid toolbar;
  # - actions: buttons on the right of the page title (Shell::PageHeaderComponent actions).
  #
  class PageComponent < ViewComponent::Base
    renders_one :toolbar_extra
    renders_one :actions

    # CSS classes of the Datagrid table
    TABLE_CLASS = 'table table-hover table-sm'

    # == Params:
    # - title: page title;
    # - model: the GogglesDb model class of the rows (edit modal & toolbar; nil without a grid);
    # - grid: the Datagrid instance (nil for a bespoke body);
    # - toolbar: Grid::ToolbarComponent options (e.g. <tt>{ create: false, destroy: false }</tt>);
    # - domain: what the API index call gave, as returned by the APIGridIndex <tt>api_grid_domain</tt> helper
    #   (<tt>count:, page:, per_page:, rows:, filter_params:, index_params:, error:</tt>);
    # - section_id: DOM id of the page section ('data-grid'; trainings: 'data-list').
    def initialize(title:, model: nil, grid: nil, toolbar: {}, domain: {}, section_id: 'data-grid') # rubocop:disable Metrics/ParameterLists
      super()
      @title = title
      @model = model
      @grid = grid
      @toolbar = toolbar.to_h
      @domain = domain.to_h
      @section_id = section_id
    end

    # (the slots are set by the block: evaluate it before the header and the toolbar render them)
    def before_render
      content
    end

    protected

    def grid?
      @grid.present? && @model.present?
    end

    def error
      @domain[:error]
    end

    # The bespoke body is left out only for a page without a grid answered by an API error.
    def body?
      grid? || error.blank?
    end

    def count
      error ? nil : @domain[:count]
    end

    def asset_row
      @asset_row ||= @model.new
    end

    def filter_params
      @domain[:filter_params] || {}
    end

    def index_url
      helpers.url_for(controller: helpers.controller_name, action: :index, params: @domain[:index_params] || {})
    end

    def toolbar_options
      { asset_row:, controller_name: helpers.controller_name, request_params: @domain[:filter_params] }.merge(@toolbar)
    end

    def page_links
      PageLinksForArrayComponent.new(data: @grid&.assets, total_count: @domain[:count],
                                     page: @domain[:page], per_page: @domain[:per_page])
    end

    def jwt
      helpers.current_user&.jwt
    end
  end
end
