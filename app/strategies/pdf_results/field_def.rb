# frozen_string_literal: true

module PdfResults
  # = PdfResults::FieldDef
  #
  #   - version:  7-0.7.10
  #   - author:   Steve A.
  #
  # Stores field definition & data extraction properties as read from a PDF-layout-format YML
  # definition file.
  #
  # (The YAML file should contain the properties that describe how to extract individual data
  #  fields from any PDF layout converted to some kind of tabular text data.)
  #
  # Properties are R-O and set during construction. #value & #curr_buffer are changed
  # each time a FieldDef is applied.
  #
  # (This way FieldDefs can act as "hybrid DAOs", storing both current data and their access definition.)
  #
  # === FieldDefs are:
  # - stored in the +fields+ Array of a ContextDef, which in turn can be stored as "group of fields describing
  #   a data row" inside a ContextDef#rows array; (ContextDefs can contain or refer to other ContextDefs)
  # - always applicable to extract data from a source row, whether the data can be extracted or not.
  # - updated each time they are applied to a source_string (changing #value & #curr_buffer)
  #
  # === FieldDefs should have:
  # - a unique name among the same context group;
  # - a lambda (i.e. any String or FieldDef method name) or a format (a Regexp) for field value extraction;
  #   when +format+ is missing, +name+ will be used as an inclusion match to detect if the name itself is present
  #   in the string; when both format & lambda are present, application is the composition of the method calls:
  #   [1. lambda(source)] ==>(result)==> [2. format(result)]
  #
  # === FieldDefs can:
  # - belong to the same group of fields inside the a single context row
  #   (with each row group stored as an item of a <tt>ContextDef#rows</tt> array);
  # - be repeated with the same name if the context row or ContextDef is different.
  # - be referred to by name by some ContextDef properties, hence the need to have unique names
  #   (in any other case, when scanning arrays of FieldDefs the first matching field name found
  #    will be chosen).
  #
  #
  # == Supported properties & order of precedence:
  #
  # 1. <tt>name</tt>: unique identifier for this <tt>FieldDef</tt>; this field name must remain unique only
  #    among the same group of sibling fields, but can be repeated in another group (or another context row).
  #    Always required.
  #
  # 2. <tt>lambda</tt>: any String or <tt>FieldDef</tt> method name that will be called on the source string
  #    (with *no* parameters); +lambda+ can also be an array of method names, applied in order as a
  #    composition of methods running on the results of the previous ones.
  #    (Lambdas are applied _before_ +format+.)
  #    So that if...
  #
  #    <code>
  #      lambda = %w[strip split]; format = nil; pop_out = nil # (defaults to true)
  #    </code>
  #
  #    ...field name will be searched among the result array, as in:...
  #
  #    <code>
  #      source_string.strip.split
  #    </code>
  #
  #    ...returning itself as extracted value, while, at the same time, removing it from the source_string.
  #
  # 3. <tt>token_start</tt> / <tt>token_end</tt>: specific index (0..N) inside the current string buffer
  #    for applying the format. These 2 "range-limiting" properties will create a sort of sub-buffer that
  #    will be piped into the next phase. (^1)
  #    (Also of note: applied before the following two.)
  #
  # 4. <tt>starts_with</tt> / <tt>ends_with</tt>: prefix & postfix String values that may delimit
  #    the actual applicable token substring inside the source buffer. (^1)
  #    <code>source_string.index(starts_with|ends_with)</code> will be used to delimit the current
  #    source buffer.
  #
  # 5. <tt>format</tt>: a Regexp matching any substring inside the source buffer; (^2)
  #    when +format+ is missing, +name+ will be used as a 1:1 string inclusion match on the field name itself.
  #    This is especially useful for detecting column headers strings, for example, which do not need complicated
  #    Regexp settings to detect a simple word or two.
  #
  # 6. <tt>pop_out</tt>: when +true+, removes the field value from the current source string buffer (if the format is found),
  #    to prevent mismatch with any possible follow-up fields. Only the first occurrence will be "popped-out".
  #    Also, the value will be popped-out from the source buffer as it was before the "lambda" phase,
  #    so before applying any range limiting properties for defining the domain for the format.
  #    Default: +true+.
  #
  # 7. <tt>required</tt>: external flag used when considering group of FieldDefs that need to be considered as present
  #    or not, depending if all the "required" fields have been found.
  #    Default: +true+.
  #
  #
  # === Notes:
  #
  # (^1) - Having any value set here will force-join the source buffer back into a single string
  #        when split into tokens as the result of a +lambda+.
  #        These properties are applied on the final result of <tt>lambda</tt>
  #        (so *between* +lambda+ & +format+).
  #        When not specified, the format is applied to the resulting source string buffer as is.
  #
  # (^2) - Any Regexp set for a property must be delimited by double quotes and have escape-code
  #        backslashes escaped themselves ("\s+" => "\\s+").
  #        Slash delimiters are not needed (but double quotes are in YML files).
  #        If the Regexp does not have any captures but it is matching, the value of the extracted token
  #        will be the remainder of the string starting from the matching index, as in:
  #
  #        <code>
  #          source_string[match_index..]
  #        </code>
  #
  #
  # == Example usage:
  #
  #    <code>
  #      > fld = PdfResults::FieldDef.new(name: 'edition', lambda: 'strip', format: "\\s*(\\d{1,2})\\W")
  #      > fld.extract('    25^ Meeting of Firenze    ')
  #      > fld.value
  #      => '25'
  #    </code>
  #
  class FieldDef < BaseDef
    attr_reader :value, :curr_buffer

    # List of supported String properties
    STRING_PROPS = %w[name starts_with ends_with].freeze

    # List of supported Boolean properties
    BOOL_PROPS = %w[pop_out required].freeze

    # List of supported Integer properties
    INT_PROPS = %w[token_start token_end].freeze

    # List of supported raw Object properties
    RAW_PROPS = %w[lambda format].freeze

    # List of all supported properties, regardless of value type
    ALL_PROPS = (BOOL_PROPS + INT_PROPS + STRING_PROPS + RAW_PROPS).freeze

    # Returns the list of boolean properties names as an Array of Strings.
    # To be overridden in siblings.
    def bool_props
      BOOL_PROPS
    end

    # Returns the list of *all* supported properties names as an Array of Strings.
    # To be overridden in siblings.
    def all_props
      ALL_PROPS
    end
    #-- -----------------------------------------------------------------------
    #++

    # Creates a new Field Definition.
    # Each property has a getter by its own name. Boolean properties also have a <NAME>? helper
    # that returns +true+ if the property variable is set and present.
    #
    # == Required properties:
    # - +name+ => name of this field
    #
    def initialize(properties = {})
      super

      # Preset defaults:
      default_format_val = format.present? && properties.stringify_keys.include?('format') ? format : "\\W*(#{name})\\W*"
      @format = Regexp.new(default_format_val, Regexp::IGNORECASE)
      @pop_out = [true, 'true', nil, ''].include?(pop_out)    # (default true for blanks)
      @required = [true, 'true', nil, ''].include?(required)  # (default true for blanks)
      @value = nil
    end
    #-- -----------------------------------------------------------------------
    #++

    class_eval do
      # Getters
      ALL_PROPS.each do |prop_key|
        define_method(prop_key.to_s.to_sym) { instance_variable_get(:"@#{prop_key}") if instance_variable_defined?(:"@#{prop_key}") }
      end
      # Define additional specific instance helper methods just for boolean values:
      BOOL_PROPS.each do |prop_key|
        define_method(:"#{prop_key}?") { send(prop_key).present? if respond_to?(prop_key) }
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Resets internal reference from last #extract() result.
    def clear
      @value = @curr_buffer = nil
    end

    # Alias for #value. Assumes #extract() has already been called.
    # === Note:
    #
    def key
      @value
    end
    #-- -----------------------------------------------------------------------
    #++

    # Updates the internal members #value and #curr_buffer by applying:
    #
    # 1. any +lambda+ method set preserving order (either none, one or a list of string methods)
    #    passing the result onto each following step;
    #    if the lambda result is an array, each following step will be applied to each item
    #    of the flattened result;
    #
    # 2. any range-limiting indexes, piping the result onto each following step;
    #
    # 3. +format+ (any String converted to Regexp) or +name+, applied as final matchers on the current buffer result.
    #    When +format+ is missing, +name+ will be used as a 1:1 string inclusion match on the field name itself.
    #    If the lambda result is an Array, only its first item matching the format will be used as +value+.
    #
    # == Params
    # - <tt>source_row</tt> => String row or buffer to be processed
    #
    # == Returns
    # The resulting string buffer after all lambdas and format are applied and the #value has
    # been extracted and updated.
    #
    # === Notes:
    # - +#value+ will become +nil+ if no data extraction was possible and
    #   will be reset (together with #curr_buffer) upon each call of #extract.
    #
    # - Any resulting string +#value+ will be automaticaly stripped at the end of the process.
    #
    # - Any range limiting property (i.e. 'token_start', 'token_end', 'starts_with' and 'ends_with')
    #   will contribute to build a temporary sub-buffer (a "parsing token") for the following "format" step,
    #   but won't be used to actually clip the resulting source buffer itself.
    #   Even when "format" captures a value inside this sub-buffer and "pop-out" is true, only the value
    #   will be extracted (just the first found occurrence) from the source buffer, leaving the rest "as is".
    #
    # - Setting "pop-out" to false while using the range limiting properties as indexes for column data
    #   allows a more straightforward data extraction in text layouts that have an quasi-fixed spacing
    #   (as it is the case for converted PDF files).
    #
    def extract(source_row)
      # Always reset current data at start:
      clear

      if lambda.is_a?(Array)
        lambda.each { |curr_lambda| source_row = apply_lambda(curr_lambda, source_row) }
      elsif lambda.is_a?(String)
        source_row = apply_lambda(lambda, source_row)
      end
      return unless source_row.present? # Bail out if there's nothing to extract

      # Index properties require a plain source string (if split):
      source_row = source_row.join("\r\n") if source_row.respond_to?(:join) &&
                                              (token_end.present? || token_start.present? ||
                                              starts_with.present? || ends_with.present?)
      # Apply range delimiting (sub-)indexes if requested & possible -- end delimiter first ALWAYS:
      # (these should concur only in better defining format's domain and not alter the source buffer)
      src_token = source_row&.dup
      src_token = src_token[..token_end] if src_token.present? && token_end.present?
      src_token = src_token[token_start..] if src_token.present? && token_start.present?

      if src_token.present? && ends_with.present?
        # Source should end the index before the start of the ends_with token:
        idx = src_token.index(ends_with)
        src_token = src_token[..(idx - 1)] if idx
      end
      if src_token.present? && starts_with.present?
        # Source should start the index after the end of the starts_with token:
        idx = src_token.index(starts_with)
        src_token = src_token[(idx + starts_with.length)..] if idx
      end

      # Apply format if possible:
      if src_token.present? && format.present?
        @last_source_before_format = src_token.dup
        result = apply_format(src_token)
        @value = result.strip if result.is_a?(String)
      end

      # Always re-collate split tokens at the end:
      source_row = source_row.join("\r\n") if source_row.respond_to?(:join)

      # Pop-out the result value from the source buffer:
      source_row.sub!(@value, '') if pop_out && @value.present?
      @curr_buffer = source_row
    end
    #-- -----------------------------------------------------------------------
    #++

    # Debug helper: converts instance contents into a viewable string representation, with a list of active properties.
    def to_s
      output = "\r\n\t\t[<#{name}>]\r\n"
      ALL_PROPS.each do |prop_key|
        next if prop_key == 'name' # (Don't output the name twice)

        next unless instance_variable_defined?(:"@#{prop_key}")

        prop_val = instance_variable_get(:"@#{prop_key}")
        prop_val = "\"#{prop_val}\"" if prop_val.is_a?(String)
        output << "\t\t- #{prop_key.ljust(11, '.')}: #{prop_val}\r\n" if prop_val.present?
      end

      output
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
