# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.5.05
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowBoolValueSwitchComponent
  #
  # Renders a slider/switch boolean toggle for any single boolean column associated to
  # an API edit action.
  #
  # This slider will act (on-click) as a button to the /update controller action.
  # (So this behaves differently from its companion Switch:: version that can be
  # used inside a form.)
  #
  class RowBoolValueSwitchComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Options: (all *required*)
    # - <tt>asset_row</tt>:
    #   row instance to be processed.
    #
    # - <tt>controller_name</tt>:
    #   controller action name inplementing the update action required for the model row.
    #
    # - <tt>column_name</tt>:
    #   boolean column name to be updated in value; its current value in asset_row will set the default.
    #
    # - <tt>bkgnd_color</tt>:
    #   background color for the ON switch position;
    #   default: 'green' (override with 'red' or others).
    #
    # - <tt>true_color</tt>:
    #   text color for the ON switch position;
    #   default: 'text-success' (override with 'text-danger' or others).
    #
    # - <tt>true_icon</tt>:
    #   unicode gliph for the ON switch position;
    #   default 'fa-check' (override with 'fa-ban' or others).
    #
    def initialize(asset_row:, controller_name:, column_name:, bkgnd_color: 'green',
                   true_color: 'text-success', true_icon: 'fa-check')
      super
      @asset_row = asset_row.reload # Force data refresh
      @controller_name = controller_name
      @column_name = column_name
      @bkgnd_color = bkgnd_color
      @true_color = true_color
      @true_icon = true_icon
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present? && @column_name.present?
    end

    private

    # Returns the destination path for the button action.
    def action_path_for_params
      url_for(only_path: true, controller: @controller_name, action: :update, id: @asset_row.id)
              # WIP: @column_name => @asset_row.send(@column_name)
    end

    # Returns the unique DOM +name+ for the hidden field inside the PUT form.
    def hidden_field_name
      "#{@column_name}[#{@asset_row.id}]"
    end

    # Returns the unique DOM +ID+ for the hidden field inside the PUT form.
    def hidden_field_id
      "#{@column_name}_#{@asset_row.id}"
    end

    # Returns +true+ if the <tt>@asset_row#column_name</tt> is +present?+; +false+ otherwise.
    def turned_on
      @asset_row.send(@column_name).present?
    end

    # Returns the stringified JS handler for the onclick event of
    # the slider switch.
    def onclick_js_handler
      <<-DOC
      document.querySelector('##{hidden_field_id}')
              .value = (
                document.querySelector('##{hidden_field_id}').value == 'true' ? 'false' : 'true'
              );

      document.querySelector('#frm-#{hidden_field_id}')
              .submit();
      DOC
    end
  end
end
