class BaseGrid
  include Datagrid

  self.default_column_options = {
    # Uncomment to disable the default order
    # order: false,
    # Uncomment to make all columns HTML by default
    # html: true,
  }

  # Enable forbidden attributes protection
  # self.forbidden_attributes_protection = true

  # Date column formatter helper
  #
  # == Params:
  # - name: column name
  # - args: options hash (blocks are supported)
  #
  def self.date_column(name, *args)
    column(name, *args) do |model|
      format(block_given? ? yield : model.send(name)) do |date|
        date.strftime("%d-%m-%Y")
      end
    end
  end

  # Sortable column formatter helper
  #
  # == Params:
  # - name: column name
  # - args: options hash (blocks are supported)
  #
  def self.sortable_column(name, *args)
    column(
      name,
      order: proc { |scope|
        scope.sort{ |a, b| a&.send(name) <=> b&.send(name) }
      },
      order_desc: proc { |scope|
        scope.sort{ |a, b| b&.send(name) <=> a&.send(name) }
      }
    ) do |model|
      block_given? ? yield : model.send(name)
    end
  end
end
