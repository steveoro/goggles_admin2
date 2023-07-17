# frozen_string_literal: true

#
# = Issue-specific components module
#
#   - version:  7.0.5.03
#   - author:   Steve A.
#
module Issue
  #
  # = Issue::CheckButtonComponent
  #
  # Renders a single button linking to the issues/check/:id action
  # if the issue type allows a #check action on it (otherwise renders nothing).
  #
  class CheckButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Options
    # - <tt>asset_row</tt>:
    #  the asset row (<tt>GogglesDb::Issue</tt>) to be processed.
    #  (*required*)
    #
    def initialize(asset_row:)
      super
      @asset_row = asset_row
    end

    # Skips rendering unless the required parameters are set and the current
    # issue type allows this action button.
    def render?
      # No check button for generic bugs:
      @asset_row.present? && @asset_row.code != '4'
    end

    private

    # Returns the unique DOM ID for the button link.
    def dom_id
      "btn-check-type#{@asset_row.code}-#{@asset_row.id}"
    end
  end
end
