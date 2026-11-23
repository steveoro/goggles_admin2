# frozen_string_literal: true

#
# = Issue-specific components module
#
#   - version:  7.0.5.03
#   - author:   Steve A.
#
module Issue
  #
  # = Issue::StatusButtonsComponent
  #
  # Renders a button group with one form-PUT button for each possible status value.
  #
  # Each button will call #api_issue_path for setting the associated status to
  # the specified Issue row.
  #
  class StatusButtonsComponent < ViewComponent::Base
    # Bootstrap outline style of the button for each status value (0..6)
    BUTTON_STYLES = %w[secondary info primary secondary success danger danger].freeze

    # Creates a new ViewComponent
    #
    # == Options
    # - <tt>asset_id</tt>:
    #  the asset (<tt>GogglesDb::Issue</tt>) ID of the row to be processed.
    #  (*required*)
    #
    # - <tt>asset_status</tt>:
    #  the status value from the same row.
    #  (*required*)
    #
    def initialize(asset_id:, asset_status:)
      super()
      @asset_id = asset_id
      @asset_status = asset_status
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_id.present? && @asset_status.present?
    end

    protected

    # Returns the DOM ID for the button representing the specified +status+
    def button_id_for(status)
      case status
      when 0
        "frm-st-new-#{@asset_id}"
      when 1
        "frm-st-review-#{@asset_id}"
      when 2
        "frm-st-process-#{@asset_id}"
      when 3
        "frm-st-pause-#{@asset_id}"
      when 4
        "frm-st-close-#{@asset_id}"
      when 5
        "frm-st-rejdup-#{@asset_id}"
      when 6
        "frm-st-rejmiss-#{@asset_id}"
      end
    end

    # Returns the CSS class for the button representing the specified +status+ (0..6)
    def button_class_for(status)
      disabled = @asset_status.to_i == status.to_i
      margins = status == 6 ? 'mx-0' : 'ms-0 me-1'
      "btn btn-sm btn-outline-#{BUTTON_STYLES[status]} px-1 py-0 #{margins} my-0 #{'disabled' if disabled}"
    end

    # Returns the CSS class for the icon inside the button representing the specified +status+
    def icon_class_for(status)
      case status
      when 0
        'fa fa-envelope-open-o'
      when 1
        'fa fa-eye'
      when 2
        'fa fa-cog'
      when 3
        'fa fa-hourglass-half'
      when 4
        'fa fa-check'
      when 5
        'fa fa-clone'
      when 6
        'fa fa-question'
      end
    end
  end
end
