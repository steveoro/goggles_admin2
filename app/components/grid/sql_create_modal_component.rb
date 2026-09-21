# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.10.48
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::SqlCreateModalComponent
  #
  # Renders an hidden modal form with 3 DB-lookup widgets (season, team & user selection),
  # used by the bespoke "+ SQL create" toolbar button of the team_managers dashboard.
  #
  # All 3 widgets are resolved against the *localhost* DB through the LookupController
  # endpoints (<tt>/lookup/:domain</tt>), assuming localhost data is in-sync with production.
  #
  # The resulting action for the form POST will be set to:
  # <tt>url_for(only_path: true, controller: @controller_name, action: @form_action)</tt>
  #
  # Field names are namespaced under "<tt><BASE_DOM_ID>[<field>]</tt>" (i.e. "sql-create[season_id]")
  # to avoid DOM ID & param name clashes with the flat-named fields already rendered by
  # Grid::EditModalComponent on the same page.
  #
  class SqlCreateModalComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name linked to this modal form (*required*)
    #
    # - <tt>jwt</tt>: required session JWT forwarded to the lookup widgets (*required*)
    #
    # - <tt>base_dom_id</tt>: base DOM ID & parameter namespace for the modal container, its
    #   input form (<tt>"frm-<BASE_DOM_ID>"</tt>) and all the lookup widget fields; defaults to "sql-create".
    #
    # - <tt>form_action</tt>: controller action name for the form POST; defaults to <tt>:sql_create</tt>.
    #
    # - <tt>grid_name</tt>: Datagrid parameter name used for the pass-through of the current
    #   filtering values; defaults to <tt>'team_managers_grid'</tt>.
    #
    def initialize(controller_name:, jwt: nil, base_dom_id: 'sql-create', form_action: :sql_create,
                   grid_name: 'team_managers_grid')
      super()
      @controller_name = controller_name
      @jwt = jwt
      @base_dom_id = base_dom_id
      @form_action = form_action
      @grid_name = grid_name
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present? && @jwt.present? && @base_dom_id.present?
    end
    #-- -----------------------------------------------------------------------
    #++

    protected

    # Base URL for the localhost-DB lookup endpoints used by the autocomplete widgets.
    # (@see LookupController)
    def lookup_base_url
      '/lookup'
    end
  end
end
