# frozen_string_literal: true

module PdfResults
  # = PdfResults::ContextDef
  #
  #   - version:  7-0.5.22
  #   - author:   Steve A.
  #
  #
  # Stores a parsing context definition, compiled from a parsing layout format YML file.
  # A ContextDef holds all properties, formats & lambdas applicable to subset of source lines.
  #
  # == Terms & notable features:
  # - "type name" (or just "type): type or name of the context;
  #    used also as "master" key when storing groups of ContextDAOs.
  #
  # - "context key": actual key value that should identify uniquely a context instance from another;
  #   can span *multiple* lines.
  #
  # - "context start": a ContextDef usually implies the start of a new context which
  #   will hold all the fields and values associated with it;
  #   when a ContextDef doesn't start a new wrapping context, then it's a filler or
  #   a gaping section in the layout.
  #
  # - "parent": each ContextDef can be a sibling of a single parent,
  #   or +nil+ when it's at root level in the hierarchy depth.
  #
  # - "fields": each ContextDef can hold multiple fields and dedicated format "lambdas"
  #   that will be used to extract the field values and store them inside a destination
  #   ContextDAO.
  #
  # - "applicable": +true+ only whe ContextDef satisfies its key def condition(s);
  #   if not applicable, usually the current context def should revert to the parent (or nil, if not defined).
  #
  # - "props" (or "conditions"): allow checking context key validity and general context applicability;
  #   define how the key subset should look & behave as an overall sub-format
  #
  class ContextDef
    attr_reader :name, :fields, :rows

    # List of supported Boolean properties
    BOOL_PROPS = %w[context_start optional repeat repeat_each_page spaced].freeze

    # List of supported Integer properties
    INT_PROPS = %w[
      at_fixed_row only_before_row only_from_row row_span max_row_span
      token_start_at token_end_at remainder_left_of remainder_right_of
    ].freeze

    # List of supported String properties
    STRING_PROPS = %w[name parent starts_with remainder].freeze

    # List of supported raw Object properties
    RAW_PROPS = %w[rows column_defs data_columns fields lambda format].freeze

    # List of all supported properties, regardless of value type
    ALL_PROPS = (BOOL_PROPS + INT_PROPS + STRING_PROPS + RAW_PROPS).freeze

    # Creates a new Context Definition.
    # Each property has a getter by its own name. Boolean properties also have a <NAME>? helper
    # that returns +true+ if the property variable is set and present.
    #
    # == Required properties:
    # - +name+ => name of this context section
    #
    # == Some frequently used properties:
    # - +parent_name+     => type name of the parent context def (can be +nil+ for sections at the root level)
    # - +context_start+   => +true+: start of new sub context
    # - +repeat+          => repeat check for every subset of key_span total source lines
    # - +optional+        => context check never fails
    # - +only_before_row+ => don't check if row index (0..N) is >= this
    # - +only_from_row+   => don't check if row index (0..N) is < this
    # - +at_fixed_row+    => check if row index (0..N) is == this
    #
    # - +rows+          => an Array of Hash, each hash item is a set of row properties
    # - +fields+        => an Array of Hash, each hash item is a set of field properties
    # - +column_defs+   => an Array of Hash, each hash item is a set of column properties (tipically, just 'name' & 'format')
    # - +data_columns+  => Hash of field properties, usually defining a repeatable row of data that will rely on the currently set 'column_defs'
    #
    def initialize(properties = {})
      raise "Missing required 'name' for context section!" unless properties.key?('name')

      init_supported_properties
      properties.each do |key, value|
        # Set only supported properties as member variables:
        var_name = "@#{key}".to_sym
        instance_variable_set(var_name, value) if ALL_PROPS.include?(key.to_s)
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    class_eval do
      # Getters
      ALL_PROPS.each do |prop_key|
        define_method(prop_key.to_s.to_sym) { instance_variable_get("@#{prop_key}") if instance_variable_defined?("@#{prop_key}") }
      end
      # Define additional specific instance helper methods just for boolean values:
      BOOL_PROPS.each do |prop_key|
        define_method("#{prop_key}?".to_sym) { send(prop_key).present? if respond_to?(prop_key) }
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the Hash of field properties for the row definition at row_index;
    # an empty Hash otherwise.
    def field_properties_at(row_index)
      return [] unless @rows.is_a?(Array) && @rows[row_index].is_a?(Hash)

      @rows[row_index].fetch('fields', {})
    end

    # Returns the flattened Array of all field properties as collected among all the
    # row definitions of this section.
    #
    # Each field object is an Hash of properties (usually, at least, 'name' and some kind
    # of lambda checker or a formatting Regex).
    #
    # Returns an empty array when no 'rows' or 'fields' properties have been included.
    def all_field_properties
      return [] unless @rows.is_a?(Array)

      @rows.filter_map { |hsh| hsh['fields'] }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Checks if this ContextDef can be applied to the array of <tt>source_rows</tt>,
    # starting from <tt>scan_index</tt>.
    #
    # == Params
    # - <tt>source_rows</tt>  => array of Strings representing the portion of the text page that has to be parsed
    # - <tt>scan_index</tt>   => starting index (0..N) for scanning the source_rows
    #
    # == Returns
    # +true+ if this section/context definition can be applied to the source rows;
    # +false+ otherwise.
    #
    # === NOTE:
    # 1. Non-applicable ContextDef shouldn't even be considered for validation & data extraction.
    # 2. Being "applicable" doesn't automatically imply that a ContextDef will satisfy all
    #    its conditional properties: a validity check must be performed also.
    #    (Applicable => Valid => actual data extraction)
    #
    # @see #valid?, #extract
    def applicable?(source_rows, scan_index)
      # TODO
    end

    # Assuming this ContextDef is 'applicable', this checks if all the required properties
    # are satisfied (for <tt>source_rows</tt> starting from <tt>scan_index</tt>).
    #
    # == Params
    # - <tt>source_rows</tt>  => array of Strings representing the portion of the text page that has to be parsed
    # - <tt>scan_index</tt>   => starting index (0..N) for scanning the source_rows
    #
    # == Returns
    # +true+ if this ContextDef is valid for the supplied source_rows @ scan_index;
    # +false+ otherwise.
    #
    # === NOTE:
    # ContextDef NOT valid => format checking failure
    # @see #applicable?, #extract
    def valid?(source_rows, scan_index)
      # TODO
    end

    # Applies this ContextDef extracting its field values if any (from <tt>source_rows</tt> starting from <tt>scan_index</tt>)
    # assuming it can be applied and it's valid.
    #
    # == Params
    # - <tt>source_rows</tt>  => array of Strings representing the portion of the text page that has to be parsed
    # - <tt>scan_index</tt>   => starting index (0..N) for scanning the source_rows
    #
    # == Returns
    # The resulting Hash of key fields with the extracted corresponding values.
    # @see #applicable?, #valid?
    def extract(source_rows, scan_index)
      # TODO
    end

    # Debug helper: converts DAO contents to a viewable multi-line string representation
    # that includes the whole hierarchy.
    # def to_s
    #   print("#{@parent.key} +--> ".rjust(20)) if @parent.present?
    #   printf("[%s] %s\n", @key, @fields)
    #   @contexts.each { |dao| print(dao.to_s) }
    #   @items.each_with_index { |itm, idx| printf("%20s#{idx}. #{itm.to_s}\n", nil) }
    #   nil
    # end

    private

    # Initializer for all supported property variables
    def init_supported_properties
      ALL_PROPS.each do |prop_key|
        # Store property value in dedicated instance variable:
        instance_variable_set("@#{prop_key}".to_sym, nil)
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
