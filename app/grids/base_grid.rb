# frozen_string_literal: true

# = BaseGrid
#
# Common DataGrid base.
#
class BaseGrid
  include Datagrid

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

  # Date column formatter helper
  #
  # == Params:
  # - <tt>name</tt>: column name
  # - <tt>args</tt>: options hash (blocks are supported)
  #
  def self.date_column(name, *args)
    column(name, *args) do |model|
      format(block_given? ? yield : model.send(name)) do |date|
        date.strftime('%Y-%m-%d')
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
    column(:selected, html: true, order: false, mandatory: mandatory) do |record|
      content_tag(:div, class: 'text-center') do
        check_box_tag("row-#{record.id}", record.id, false, class: 'grid-selector')
      end
    end
  end

  # Action column setter.
  # Renders a mini action toolbar for the current record row.
  #
  # == Params:
  # - <tt>destroy</tt>      => true/false to toggle display of the 'delete row' action button
  # - <tt>edit</tt>         => true/false to toggle display of the 'edit row' action button
  # - <tt>label_method</tt> => method to call on the current row to get a displayable label
  # - <tt>mandatory</tt>    => always show column (@see https://github.com/bogdan/datagrid/wiki/Columns#columns-visibility)
  #
  def self.actions_column(edit:, destroy:, label_method: nil, mandatory: false)
    column(:actions, html: true, order: false, edit: edit, destroy: destroy,
                     label_method: label_method, mandatory: mandatory)
  end
end
