# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.5.03
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::FilterLabelsComponent
  #
  # Renders a string label on a single row representing the current active
  # datagrid filters found in the specified parameters.
  #
  class FilterLabelsComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Options
    # - <tt>filter_params</tt>:
    #  the <tt>params</tt> hash already whitelisted for datagrid parameters.
    #  (*required*)
    #
    def initialize(filter_params:)
      super
      @filter_params = filter_params
    end

    # Skips rendering unless the required parameters are set
    def render?
      @filter_params.present?
    end

    protected

    # Returns a String representing all the current filtering parameters for display.
    # Parameters keys are not localized in this version.
    def filter_labels
      @filter_params.reject { |key, value| value.blank? || key == 'order' || key == 'descending' }
                    .to_hash
                    .map { |key, value| "#{key}: #{value}" }
                    .join(', ')
    end
  end
end
