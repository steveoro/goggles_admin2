# frozen_string_literal: true

module ComboBox
  #
  # = ComboBox::AutocompleteCityComponent
  #
  # --> Admin2 bespoke version <--
  #
  # Based on goggles_main AutocompleteCityComponent with the following differences:
  # - Renders ComboBox::AutocompleteComponent internally (not inheritance)
  # - Adds server-side JWT support (jwt parameter)
  # - Preserves additional hidden fields (city_area, city_country_code) in template
  # - Uses bound_query_param for country_code filtering
  #
  class AutocompleteCityComponent < ViewComponent::Base
    # Initialize the component with the given options.
    #
    # @param options [Hash] Additional options for the component.
    #
    # == Options:
    # - :free_text [Boolean] Whether to allow free text input.
    # - :required [Boolean] Whether the field is required.
    # - :wrapper_class [String] The class for the wrapper.
    # - :default_row [GogglesDb::City] The default row to preselect.
    # - :jwt [String] Server-side JWT for API authentication.
    #
    def initialize(options = {})
      super()
      @free_text = options[:free_text] || false
      @required = options[:required] || false
      @wrapper_class = options[:wrapper_class] || 'col'
      @jwt = options[:jwt]
      @default_row = options[:default_row] if options[:default_row].instance_of?(GogglesDb::City)
    end

    private

    def value_options(default_row)
      return nil unless default_row

      options_for_select({ default_row.name => default_row.id.to_i }, default_row.id.to_i)
    end
  end
end
