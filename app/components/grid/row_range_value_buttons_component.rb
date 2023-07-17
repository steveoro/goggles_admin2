# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.5.03
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowRangeValueButtonsComponent
  #
  # Renders a couple of buttons able to raise or lower any integer column value
  # inside a valid specified range.
  #
  class RowRangeValueButtonsComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Options: (all *required*)
    # - <tt>asset_row</tt>:
    #   the row instance to be processed.
    #
    # - <tt>controller_name</tt>:
    #   the controller action name inplementing the update action required for the model row.
    #
    # - <tt>column_name</tt>:
    #   the integer column name to be updated in value, either up or down.
    #
    # - <tt>value_range</tt>:
    #   the range of accepted values.
    #
    def initialize(asset_row:, controller_name:, column_name:, value_range:)
      super
      @asset_row = asset_row
      @controller_name = controller_name
      @column_name = column_name
      @value_range = value_range
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present? && @column_name.present? &&
        @value_range.respond_to?(:cover?) && @asset_row.respond_to?(@column_name)
    end

    protected

    # Returns +true+ if an increase in value of the specified @column_name of @asset_row
    # is acceptable (is inside the specified @value_range).
    # Returns +false+ otherwise.
    def can_increase?
      @value_range.cover?(@asset_row.send(@column_name) + 1)
    end

    # Returns +true+ if an decrease in value of the specified @column_name of @asset_row
    # is acceptable (is inside the specified @value_range).
    # Returns +false+ otherwise.
    def can_decrease?
      @value_range.cover?(@asset_row.send(@column_name) - 1)
    end

    # Returns the destination path for the '+' button action. A blank link unless the action can
    # be carried out.
    def action_path_for_increase
      return '#' unless can_increase?

      url_for(only_path: true, controller: @controller_name, action: :update, id: @asset_row.id,
              @column_name => @asset_row.send(@column_name) + 1)
    end

    # Returns the destination path for the '-' button action. A blank link unless the action can
    # be carried out.
    def action_path_for_decrease
      return '#' unless can_decrease?

      url_for(only_path: true, controller: @controller_name, action: :update, id: @asset_row.id,
              @column_name => @asset_row.send(@column_name) - 1)
    end
  end
end
