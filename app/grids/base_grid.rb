# frozen_string_literal: true

# = BaseGrid
#
# Common DataGrid base.
#
class BaseGrid
  include Datagrid

  self.cached = true

  # Common data domain for all subclasses.
  #
  # To set the domain with a list of instances rebuilt from an API responses do:
  # > MyGrid.data_domain = @model_instances_list
  class_attribute(:data_domain, default: [])

  self.default_column_options = {
    # Uncomment to disable the default order
    # order: false,
    # Uncomment to make all columns HTML by default
    # html: true,
  }

  # Enable forbidden attributes protection
  # self.forbidden_attributes_protection = true
  #-- -------------------------------------------------------------------------
  #++

  # Boolean column formatter helper
  #
  # == Params:
  # - <tt>name</tt>: column name
  # - <tt>args</tt>: options hash (blocks are supported)
  #
  def self.boolean_column(name, *args)
    column(name, *args) do |model|
      format(block_given? ? yield : model.send(name)) do |value|
        value ? '✔' : '-'
      end
    end
  end

  # Selection column setter.
  # Renders a selection column containing a single checkbox.
  #
  # Each selection row will store the current row ID as value.
  # All selection checkboxes will have the 'grid-selector' class.
  #
  # == Params:
  # - <tt>mandatory</tt> => always show column (@see https://github.com/bogdan/datagrid/wiki/Columns#columns-visibility)
  #
  # == Use case examples (in ES6):
  #
  # (Assuming a single Datagrid per page)
  #
  # Toggle all selection checkboxes:
  #
  #   $("input[type='checkbox'].grid-selector").click();
  #
  # Retrieve the list of selected IDs:
  #    const idList = $("input[type='checkbox'].grid-selector:checked").toArray()
  #      .map((node) => { return node.value })
  #
  def self.selection_column(mandatory: false)
    column(:selected, html: true, order: false, mandatory:) do |record|
      content_tag(:div, class: 'text-center') do
        check_box_tag("row-#{record.id}", record.id, false, class: 'grid-selector')
      end
    end
  end

  # Action column setter.
  # Renders a mini action toolbar for the current record row.
  #
  # == Params:
  # - <tt>destroy</tt>
  #   => [true]/false to toggle display of the 'delete row' action button (default: true)
  #
  # - <tt>edit</tt>
  #   => [true]/false to toggle display of the 'edit row' action button (default: true);
  #      set this to a string to use a custom DOM ID for the modal dialog
  #
  # - <tt>clone</tt>
  #   => true/[false] to toggle display of the 'clone row' action button (default: false)
  #
  # - <tt>expand</tt>
  #   => true/[false] to toggle display of the 'expand row' action button (default: false)
  #      (Usually a link to a "GET <ENTITY_NAME/<ID>"-type request that will open in a new page)
  #
  # - <tt>label_method</tt>
  #   => method to call on the current row to get a displayable label
  #
  # - <tt>mandatory</tt>
  #   => true/[false] to always show column
  #      (@see https://github.com/bogdan/datagrid/wiki/Columns#columns-visibility)
  #
  # rubocop:disable Metrics/ParameterLists
  def self.actions_column(edit:, destroy:, clone: false, expand: false, label_method: nil, mandatory: false)
    column(:actions, html: true, order: false, edit:, destroy:,
                     clone:, expand:, label_method:, mandatory:)
  end
  # rubocop:enable Metrics/ParameterLists
end
