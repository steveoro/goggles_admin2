# frozen_string_literal: true

# = BaseGrid
#
# Common DataGrid base.
#
class BaseGrid < Datagrid::Base
  self.cached = true

  # Common data domain for all subclasses.
  #
  # To set the domain with a list of instances rebuilt from an API responses do:
  # > MyGrid.data_domain = @model_instances_list
  class_attribute(:data_domain, default: [])

  # (phase 15) Column and filter headers come from config/locales/grids.{en,it}.yml, read at render time in the current
  # locale (an explicit +header:+ option still wins; see .column_header and .filter_header).
  self.default_column_options = ->(column) { { header: -> { column.grid_class.column_header(column.name) } } }
  self.default_filter_options = ->(filter) { { header: -> { filter.grid_class.filter_header(filter.name) } } }

  # The grid's key in the 'grids.*' locale scope: the class name without 'Grid', underscored (TeamsGrid => 'teams').
  def self.i18n_key
    name.underscore.delete_suffix('_grid')
  end

  # Header of a column: 'grids.<grid>.<column>', then 'grids.defaults.<column>' (the BaseGrid helper columns:
  # selected, actions, drill), else the humanized name.
  def self.column_header(column_name)
    I18n.t("grids.#{i18n_key}.#{column_name}", default: [:"grids.defaults.#{column_name}", column_name.to_s.humanize])
  end

  # Label of a filter: 'grids.<grid>.filters.<filter>', then the header of the column with the same name.
  def self.filter_header(filter_name)
    I18n.t("grids.#{i18n_key}.filters.#{filter_name}", default: column_header(filter_name))
  end

  # The i18n keys a column (or a filter, +filter: true+) header is read from, most specific first.
  def self.header_keys(name, filter: false)
    keys = ["grids.#{i18n_key}.#{name}", "grids.defaults.#{name}"]
    filter ? keys.unshift("grids.#{i18n_key}.filters.#{name}") : keys
  end

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
  # rubocop:disable-next Metrics/ParameterLists
  def self.actions_column(edit:, destroy:, clone: false, expand: false, label_method: nil, mandatory: false)
    column(:actions, html: true, order: false, edit:, destroy:,
                     clone:, expand:, label_method:, mandatory:)
  end
end
