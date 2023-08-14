# frozen_string_literal: true

module PdfResults
  # = PdfResults::ContextDAO
  #
  #   - version:  7-0.5.22
  #   - author:   Steve A.
  #
  #
  # Wraps a subset of contextual data extracted from PDF/TXT parsing
  # into a hierarchy-capable object.
  #
  # Each ContextDAO can store any set of individual fields ("header" attributes) with values
  # plus:
  # - an internal array of sibling contexts;
  # - an internal array of "leaf" items (any object);
  # - a reference to its parent context, if any.
  #
  #
  # == Typical usage:
  #
  # root = ContextDAO.new(
  #   key: 'header', value: nil, parent: nil,
  #   fields: {
  #     'description' => 'My Awesome Meeting',
  #     'date' => '2023-07-05'
  #   }
  # )
  # ...Or, without specifying the 'fields' parameter:
  # root.add_field('description', 'My Awesome Meeting')
  # root.add_field('date', '2023-07-05')
  #
  # ev = root.add_context('event', '100 SL')
  # ...Or:
  # ev = ContextDAO.new(key: 'event', value: '100 SL', parent: root)
  #
  # cat1 = ev.add_context('category', 'M 45 M')
  # res1 = cat1.add_item('rank' => '1', 'name' => 'Johnny Mnemonic', 'timing' => '1 03 53')
  # res2 = cat1.add_item('rank' => '2', 'name' => 'Robby Roberts', 'timing' => '1 05 42')
  #
  # cat2 = ev.add_context('category', 'M 50 M')
  # res3 = cat2.add_item('rank' => '1', 'name' => 'Paul Paulie', 'timing' => '1 08 22')
  #
  class ContextDAO
    attr_reader :key, :value, :parent, :fields, :contexts, :items

    # Creates a new context DAO.
    #
    # == Params:
    # - +key+    => key name (master field name or data type) of the context
    # - +value+  => any value associated with this context (typically a string name)
    # - +parent+ => parent ContextDAO object; set this to nil for root hierarchy objects
    # - +fields+ => hash of attributes/fields of this context
    #
    def initialize(key:, value: nil, parent: nil, fields: {})
      @key = key
      @value = value
      @parent = parent
      @fields = fields
      @contexts = []
      @items = []
    end
    #-- -----------------------------------------------------------------------
    #++

    # Adds a new sibling context DAO using <tt>key</tt> and <tt>value</tt>.
    # Each new context object can store both "header fields" and sibling items.
    #
    # == Params
    # - <tt>key</tt>.....: key/field/type name of the context;
    # - <tt>value</tt>...: value associated to the +key+.
    #
    # == Returns
    # a new ContextDAO instance set with this instance as parent.
    #
    def add_context(key, value)
      @contexts << ContextDAO.new(key:, value:, parent: self)
      @contexts.last
    end

    # Adds a new "header" field <tt>name</tt> with <tt>value</tt> to the instance.
    #
    # == Params
    # - <tt>name</tt>....: string key or field name; note that any field already defined with this
    #                      same +name+ will be overwritten with +value+.
    # - <tt>value</tt>...: any object instance or value for +name+.
    #
    def add_field(name, value)
      @fields.merge!(name => value)
    end

    # Adds a new data item to the internal list of this context's items.
    #
    # A data item is basically a "leaf" in the hierarchy tree, but it can be anything,
    # even another instance of ContextDAO.
    #
    # == Params
    # <tt>value</tt>: any object value to be added to the #items list.
    #
    # == Returns
    # the value parameter itself.
    #
    def add_item(value)
      @items << value
      value
    end

    # Debug helper: converts DAO contents to a viewable multi-line string representation
    # that includes the whole hierarchy.
    def to_s
      print("#{@parent.key} +--> ".rjust(20)) if @parent.present?
      printf("[%s] %s\n", @key, @fields)
      @contexts.each { |dao| print(dao) }
      @items.each_with_index { |itm, idx| printf("%20s#{idx}. #{itm}\n", nil) }
      nil
    end
  end
end
