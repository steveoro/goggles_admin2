# frozen_string_literal: true

module ComboBox
  #
  # = ComboBox::AutocompleteTeamComponent
  #
  # --> Admin2 bespoke version <--
  #
  # Based on goggles_main pattern (no direct equivalent) with the following differences:
  # - Renders ComboBox::AutocompleteComponent internally
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
    # - label: nil        => custom label text; defaults to I18n.t('best_results.list.team')
    # - jwt: nil          => server-side JWT for API authentication (required)
    #
    def initialize(options = {})
      super()
      @base_name = options[:base_name] || 'team'
      @default_row = options[:default_row]
      @free_text = options[:free_text] || false
      @required = options[:required] || false
      @label = options[:label]
      @jwt = options[:jwt]
    end

    # Render ComboBox::AutocompleteComponent with configured options
    def call
      render(ComboBox::AutocompleteComponent.new(
               api_url: 'teams',
               label: @label || I18n.t('best_results.list.team'),
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
