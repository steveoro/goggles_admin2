# frozen_string_literal: true

module ComboBox
  #
  # = ComboBox::DbTeamComponent
  #
  # Creates a Select2-based combo-box for GogglesDb::Team lookup.
  # Uses the standard DbLookupComponent configured for the 'api/v3/teams/lookup' endpoint.
  #
  # @see ComboBox::DbLookupComponent
  #
  class DbTeamComponent < ViewComponent::Base
    delegate :current_user, to: :helpers # Needed for JWT token

    # Creates a new ViewComponent
    #
    # == Supported options & defaults:
    # - default_row: nil  => pre-selected GogglesDb::Team instance
    # - free_text: false  => allows/disables free text as input
    # - required: false   => sets the HTML5 'required' attribute for the select field
    # - base_name: 'team' => base name for the form fields (team_id, team_label)
    #
    def initialize(default_row: nil, free_text: false, required: false, base_name: 'team')
      super
      # Define component attributes based on initialization parameters
      @api_url     = 'teams' # Relative API path (base is assumed '/api/v3')
      @label       = I18n.t('best50m_results.index.team')
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
                                               required: @required
                                             }))
    end
  end
end
