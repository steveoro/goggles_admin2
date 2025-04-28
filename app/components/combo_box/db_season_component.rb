# frozen_string_literal: true

module ComboBox
  #
  # = ComboBox::DbSeasonComponent
  #
  # Creates a Select2-based combo-box for GogglesDb::Season lookup.
  # Uses the standard DbLookupComponent configured for the 'api/v3/seasons/lookup' endpoint.
  # Filters for 'FINA' season type by default.
  #
  # @see ComboBox::DbLookupComponent
  #
  class DbSeasonComponent < ViewComponent::Base
    delegate :current_user, to: :helpers # Needed for JWT token

    # Creates a new ViewComponent
    #
    # == Supported options & defaults:
    # - default_row: nil  => pre-selected GogglesDb::Season instance
    # - free_text: false  => allows/disables free text as input
    # - required: false   => sets the HTML5 'required' attribute for the select field
    # - base_name: 'season' => base name for the form fields (season_id, season_label)
    # - season_type_id: 1 => Default season type filter for lookup API (1 = "FIN", ...)
    #
    def initialize(default_row: nil, free_text: false, required: false, base_name: 'season', season_type_id: 1)
      super
      # Define component attributes based on initialization parameters
      @api_url     = 'seasons' # Relative API path with filter
      @label       = I18n.t('activerecord.models.season.one') # Use standard model translation
      @base_name   = base_name
      @default_row = default_row
      @free_text   = free_text
      @required    = required
    end

    # Render the underlying DbLookupComponent with configured options
    def call
      render(ComboBox::DbLookupComponent.new(@api_url, @label, @base_name,
                                             {
                                               jwt: current_user.jwt,
                                               default_row: @default_row,
                                               free_text: @free_text,
                                               query_column: 'description',
                                               required: @required
                                             }))
    end
  end
end
