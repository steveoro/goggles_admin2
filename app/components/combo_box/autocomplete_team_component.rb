# frozen_string_literal: true

module ComboBox
  #
  # = ComboBox::AutocompleteTeamComponent
  #
  # --> Admin2 bespoke version <--
  #
  # Based on goggles_main pattern (no direct equivalent) with the following differences:
  # - Renders AutocompleteComponent internally
  # - Adds server-side JWT support (jwt parameter, required)
  # - Simplified version for Admin2 team lookup usage
  #
  class AutocompleteTeamComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Supported options & defaults:
    # - default_row: nil  => pre-selected GogglesDb::Team instance
    # - free_text: false  => allows/disables free text as input
    # - required: false   => sets the HTML5 'required' attribute for the select field
    # - base_name: 'team' => base name for the form fields (team_id, team_label)
    # - jwt: nil         => server-side JWT for API authentication (required)
    #
    def initialize(default_row: nil, free_text: false, required: false, base_name: 'team', jwt: nil)
      super()
      @base_name = base_name
      @default_row = default_row
      @free_text = free_text
      @required = required
      @jwt = jwt
    end

    # Render the underlying AutocompleteComponent with configured options
    def call
      render(ComboBox::AutocompleteComponent.new(
               api_url: 'teams',
               label: I18n.t('best_results.list.team'),
               base_name: @base_name,
               free_text: @free_text,
               required: @required,
               jwt: @jwt,
               selected_id: @default_row&.id,
               selected_label: @default_row&.name
             ))
    end
  end
end
