# frozen_string_literal: true

#
# = ComboBox components module
#
#   - version:  7.0.3.32
#   - author:   Steve A.
#
module ComboBox
  #
  # = ComboBox::DbCityComponent
  #
  # --> CUSTOMIZED version for Admin2 <--
  #
  # Creates a Select2-based combo-box, with AJAX retrieval of the datasource,
  # using the StimulusJS LookupController to handle GogglesDb::City extra data fields
  # as hidden_field tags.
  #
  # @see ComboBox::DbLookupComponent
  #
  class DbCityComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # DbCityComponent uses a specialized DbLookupComponent for /cities, rendering also other
    # bound input controls for area & country code.
    #
    # The shared base name for all the controls is prefixed ('city').
    # To work properly, this assumes a single DbCityComponent per form.
    #
    # == Supported options & defaults:
    # - jwt: nil          => required session JWT for API auth. (not needed when using static values)
    # - default_row: nil  => pre-selected GogglesDb::City instance
    # - free_text: false  => allows/disables free text as input
    # - required: false   => sets the HTML5 'required' attribute for the select field
    #
    def initialize(options = {})
      super
      @api_endpoint = 'cities'
      @jwt = options[:jwt] || nil
      @free_text = options[:free_text] || false
      @required = options[:required] || false
      @default_row = options[:default_row] if options[:default_row].instance_of?(GogglesDb::City)
    end

    private

    # Prepares the default options for select when a @default_row is supplied
    def value_options
      return nil unless @default_row

      options_for_select({ @default_row.name => @default_row.id.to_i }, @default_row.id.to_i)
    end
  end
end