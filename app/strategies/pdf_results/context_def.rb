# frozen_string_literal: true

module PdfResults
  # = PdfResults::ContextDef
  #
  #   - version:  7-0.6.00
  #   - author:   Steve A.
  #
  # Stores a parsing context definition, compiled from a parsing layout format YML file.
  # A ContextDef holds all properties, formats & lambdas applicable to subset of source lines.

  # Stores context definition & data extraction properties as read from a PDF-layout-format YML
  # definition file.
  #
  # (The YAML file should contain the properties that describe how to extract individual data
  #  fields from any PDF layout converted to some kind of tabular text data.)
  #
  # Properties are R-O and set during construction. Values extracted are stored as
  # PdfResults::ContextDAO instances.
  #
  # == ContextDefs:
  # - are checked against a row buffer, starting at a specific row index (kind of a program pointer);
  # - can span multiple rows;
  # - can be delimited by special properties, starting after a certain line or ending before another
  #   one in the buffer;
  # - can start or end at specific Regex match;
  # - can be nested into other ContextDefs as sibling of a parent
  # - can contain a group of FieldDefs as #fields;
  # - can be applied to multiple rows or group or rows;
  # - are considered valid (or "applicable" for data extraction) if *all* their conditions
  #   (set by properties, rows & fields definitions) are satisfied.
  # - when applied, should yield either a ContextDAO or a nil.
  #
  # === Terms & notable features:
  # - "name" (a.k.a. "type name"): type or name of the context;
  #    used also as "master" key when storing groups of ContextDAOs.
  #
  # - "parent": each ContextDef can be a sibling of a single parent,
  #   or +nil+ when it's at root level in the hierarchy depth.
  #
  # - "format": each ContextDef can have a specific matching/capturing format for
  #   determining a super-filter for any sibling context or group of fields.
  #   Whenever present, this concurs as a context validator. (A)
  #
  # - "fields": each ContextDef can hold multiple fields and dedicated format "lambdas"
  #   that will be used to extract the field values and store them inside a destination
  #   ContextDAO as values composing its key.
  #   Whenever present, this concurs as a context validator. (B)
  #
  # - "rows": each ContextDef can hold multiple sub-context rows, which will act as subordinate
  #   sibling context sections.
  #   Whenever present, this concurs as a context validator. (C)
  #
  # - "applicable/valid": +true+ only when the ContextDef satisfies *all* its required key condition(s);
  #   this is both true for all 3 context "validators" (A, B & C above: format + fields + rows).
  #   When not applicable, usually the current context def should revert to the parent (or nil, if not defined)
  #   during layout scanning (a layout is basically a hierarchy list of ContextDef).
  #
  # - "context key": actual key value that should identify uniquely a context instance from another;
  #   can span or being extracted from *multiple* lines.
  #   Context keys can be extracted from: 1) self.format + 2) FieldDefs value(s) + 3) sub-ContextDef values
  #   in order to uniquely identify the data this context refers to, even when considering it
  #   among different groups of data fields belonging to the same type of context.
  #   This "context key" will be reset & overwritten upon each #extract() run.
  #
  #   For example, the same ContextDef wrapping up a couple of fields like 'swimmer_name' & 'swimmer_age'
  #   may refer to multiple DAOs, each one identified by a composed key having a format like:
  #   <extracted-swimmer-name-N>|<extracted-swimmer-age-N>, for each 'N' extracted swimmer enlisted in
  #   the source buffer rows. (ContextDef is the defining data type, while the DAO holds a
  #   reference to the values.)
  #
  # - "properties" (or "conditions"): these define & allow checking context key validity and
  #   applicability in general; in other words, these define how the key subset should look & behave
  #   as an overall context.
  #
  # - "context start": a ContextDef usually implies the start of a new context which
  #   will hold all the fields and values associated with it;
  #   when a ContextDef doesn't start a new wrapping context, then it's a filler or
  #   a gaping section in the layout.
  #   This is somewhat managed at layout level, to determine which context is actually
  #   extracting the data being scanned.
  #
  #
  # == Supported properties & order of precedence/application:
  #
  #  1. <tt>name</tt>: unique identifier for this ContextDef; this field name should be unique among the
  #     same group of sibling contexts, but can be repeated among different groups. Always required.
  #
  #  2. <tt>keys</tt>: [] => Array of field or context names used to compose the unique #key value identifying
  #     this context's data among other instances of the same ContextDef.
  #
  #     That is, given that each ContextDef can be applied multiple times to different sections
  #     of text, what will discriminate uniquely each data row will be the values extracted from the
  #     fields enlisted here. Default: +nil+. (Example: ['event', 'category', 'rank', 'timing'])
  #
  #     Field & Context names should all be at the same level (as in a flattened array), even when hierarchy is involved:
  #     you can specify different levels of depths just by the context or field name, if each name is unique
  #     between all contexts and fields hierarchy levels. This flat array of keys will be used as a
  #     filter to select which field or context keys will be added to the resulting key.
  #
  #     This filtering array of "key names" is not required as a resulting "implicit" key will be
  #     collated considering this:
  #
  #     - When not defined and without a format, with neither any fields nor any rows, the resulting key
  #       will be considered blank and the context will be undistinguishable in between instances
  #       (typical case for no data extraction or ignored blank lines).
  #     - When not defined but with a valid format, the implicit key will be the result of the captured format.
  #     - When not defined but with a some valid & required fields, the implicit key value will be appended with
  #       the collated map of all extracted values from all required fields, pipe separated ('|').
  #     - When not defined but with a some valid & required rows, the implicit key value will be appended with
  #       the collated map of all extracted keys from all these required sibling rows, pipe separated ('|').
  #     - If some key names are specified for #keys, only those names will be taken out as values for
  #       the resulting key. That is, if you use some context names and you also have fields defined
  #       in this context, you'll need to add also all the fields names that you need or these will be
  #       filtered out if not included in the keys list.
  #
  #  3. <tt>required</tt>: +false+ => ContextDef doesn't fail the format check if it is not found (not required)
  #     default: true (all required ContextDef must be applicable and satisfied for a format/layout check to pass).
  #     "Optional" ContextDefs never fail checks.
  #
  #  4. <tt>repeat</tt>: +true+ => ContextDef should be checked every time the current row counter moves forward;
  #     default: false.
  #
  #  5. <tt>optional_if_empty</tt>: +true+ => ContextDef doesn't fail the format check if it is not found (as in "not required")
  #     but ONLY if the scanned domain is made of empty rows (as many as the row_span).
  #     default: false.
  #
  #  6. <tt>at_fixed_row</tt>: 0..N => specific index (0..N) of the current string buffer at which
  #     checking for this ContextDef makes sense (i.e.: "check for this ContextDef only when you're at this line");
  #     These indexes are *relative* to each single page of the source document. These are useful to skip
  #     any page headers or footers.
  #     Default: nil => no specific line check.
  #
  #  7. <tt>starts_at_row</tt> / <tt>ends_at_row</tt>: 0..N => specific indexes (0..N) describing a range of lines
  #     of the current string buffer inside which checking for this ContextDef makes sense
  #     (i.e.: "do not check for this ContextDef before this line / after this line").
  #     These indexes are *relative* to each single page of the source document. These are useful to skip
  #     any page headers or footers.
  #     Range start & end can also be specified individually (which translates to [start..] or [..end] as range delimiters).
  #     If <tt>starts_at_row</tt> is set together with <tt>at_fixed_row</tt>, the latter has higher priority
  #     (validity loop will bail out if <tt>at_fixed_row</tt> is not met even if <tt>starts_at_row</tt> is set to a lower value).
  #     Default: nil => no row domain defined.
  #
  #  8. <tt>row_span</tt>: exact number of rows spanning this context; default: 1.
  #     If this ContextDef has sub-contexts, the row count of sub-contexts will be added
  #     to this row span value when increasing the scan index.
  #     Each sub-context row will add its own row span to the count of processed lines in
  #     the buffer. Zero-length contexts (in rows) are not allowed, so it is assumed that a context, at least,
  #     should have some kind of header in order for it to be recognized, spanning this row_span number of lines.
  #
  #  9. <tt>parent</tt>: parent <tt>ContextDef.name</tt>, either the String name or the reference to the
  #     instance itself; when set to the string name, the actual parent ContextDef instance
  #     should be retrieved from a lookup-list of available ContextDefs by the
  #     external class managing the formats (usually an instance of FormatParser).
  #
  #     Handling both string names & instance references is required given that the context
  #     setup YML file can store only strings. Default: +nil+ (for root-level ContextDefs).
  #
  # 10. <tt>lambda</tt>: any String or <tt>FieldDef</tt> method name that will be called on the source string
  #     (with *no* parameters); +lambda+ can also be an array of method names, applied in order as a
  #     composition of methods running on the results of the previous ones.
  #     (Lambdas are applied _before_ +format+.)
  #
  # 11. <tt>starts_with</tt> / <tt>ends_with</tt>: prefix & postfix String values that may delimit
  #     the actual applicable substring inside the source buffer.
  #     <code>source_string.index(starts_with|ends_with)</code> will be used to delimit the current
  #     source buffer (after everything else has been applied).
  #
  # 13. <tt>format</tt>: a Regexp matching any substring inside the source buffer;
  #     the format is applied on the buffer resulting from the previous steps: if split in lines, the array
  #     is collated back again before checking for any capture group. The resulting captured string value
  #     will then be split again in lines and piped forward for rows & fields checking.
  #     When +format+ is missing, it will be simply ignored (unlike FieldDefs, which have a "name" default).
  #     Compared to fields#format, this is a sort of macro-condition for the applicability/validity check
  #     and data extraction.
  #
  # 14. <tt>rows</tt>: array of <tt>ContextDef</tt>s; default: +nil+.
  #     All rows must be applicable (valid) for this ContextDef to be valid as well.
  #     Any ContextDef added to this array as sub-context should have the +parent+ property set to this
  #     instance of ease of reference during layout parsing.
  #
  # 15. <tt>fields</tt>: array of <tt>FieldDef</tt>s; default: +nil+.
  #     Each <tt>FieldDef</tt> stores an extractable data field. Use this property to define groups of
  #     fields that can be later processed into a <tt>ContextDAO</tt>.
  #     All required fields must be able to extract the data they refer to (as fields are always "valid")
  #     for this ContextDef to be valid as well.
  #
  # 16. <tt>eop</tt>: +true+ => search for this context not before +row_span+ lines reaching the end of the page/buffer;
  #     default: false.
  #     Basically, when true, will overwrite the 'starts_at_row' property with 'current_buffer.size - row_span'.
  #
  class ContextDef < BaseDef # rubocop:disable Metrics/ClassLength
    # Last valid? result; set to false upon each #valid? call.
    attr_reader :last_validation_result

    # Current progress index in scanning for this context, 0..N relative a single text buffer
    attr_reader :curr_index

    # Number of rows from the source buffer actually found, validated and consumed.
    # Note that if some rows are not required (optional), even if they shall make the validation
    # check pass they shouldn't be considered as "consumed" when not actually found.
    #
    # === Examples:
    # Considering a source domain with 3 rows, 2 of which required (1 optional):
    # - when all 3 found => consume step: 3
    # - when just the 2 min required are found => consume step: 2
    # - when not all min required rows are found => consume step: 0
    #
    # Considering a source domain with just a format (or some fields), no rows:
    # - when all requirements are matched => consume step: 1
    # - when not all requirements are satisfied => consume step: 0
    attr_reader :consumed_rows

    # Stores all [key_names, associated_key_values] extracted from a single text buffer (both required and optional)
    attr_reader :data_hash

    # Resulting ContextDAO from the latest valid?/extract run (if matching/successful).
    # Stores both the #data_hash & the #key for this context.
    # See also #ContextDAO.
    attr_reader :dao

    # List of supported String properties
    STRING_PROPS = %w[name starts_with ends_with].freeze

    # List of supported Boolean properties
    BOOL_PROPS = %w[required repeat optional_if_empty eop debug].freeze

    # List of supported Integer properties
    INT_PROPS = %w[at_fixed_row starts_at_row ends_at_row row_span].freeze

    # List of supported raw Object properties
    RAW_PROPS = %w[keys parent rows fields lambda format logger].freeze

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

    # Creates a new Context Definition.
    # Each property has a getter by its own name. Boolean properties also have a <NAME>? helper
    # that returns +true+ if the property variable is set and present.
    #
    # == Required properties:
    # - <tt>name</tt> => name of this context section
    #
    # == Additional Options:
    # - <tt>:logger</tt> => a valid Logger instance for debug output. Default: +nil+ to skip logging.
    #
    # - <tt>:debug</tt> => (default +false+) when +true+ the log messages will also
    #   be redirected to the Rails logger as an addition to the +logger+ specified above.
    #
    def initialize(properties = {})
      super

      # Preset defaults:
      @consumed_rows = 0
      @logger = logger if logger.is_a?(Logger)
      @debug = [true, 'true'].include?(debug) # (default false for blanks)
      @format = Regexp.new(format, Regexp::IGNORECASE) if format.present?
      @optional_if_empty = [true, 'true'].include?(optional_if_empty) # (default false for blanks)
      @required = [true, 'true', nil, ''].include?(required) # (default true for blanks)
      @repeat = [true, 'true'].include?(repeat)
      @eop = [true, 'true'].include?(eop)
      # == NOTE: ==
      # @row_span should default to 1 even when fields or other properties are defined (unless overridden
      # as a property value).
      # When both @fields & @rows are defined, @rows has the priority in defining the actual row span
      # and any additional group of fields defined is still considered as belonging to row #0 in the
      # overall @row_span.
      @row_span ||= rows&.count || 1
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

    # Simple helper that returns +true+ if this ContextDef is not required.
    def optional?
      !required?
    end

    # Returns the Array of *required* FieldDefs, if there are any defined; an empty Array otherwise.
    def required_fields
      return [] unless @fields.is_a?(Array)

      fld_map = []
      @fields.inject(fld_map) do |ary, fld|
        ary << fld if ary.is_a?(Array) && fld.is_a?(FieldDef) && fld.required?
      end
      fld_map
    end

    # Returns the Array of *required* sibling ContextDefs, if there are any defined; an empty Array otherwise.
    def required_rows
      return [] unless @rows.is_a?(Array)

      row_map = []
      @rows.inject(row_map) do |ary, row|
        ary << row if ary.is_a?(Array) && row.is_a?(ContextDef) && row.required?
      end
      row_map
    end

    # Returns the Hash of field names & values extracted from all #required_fields
    # if the #keys filtering array is blank or if some of these field names are included in the
    # filtering list.
    #
    # Assumes #extract() has already been called (or the keys/values will be blank).
    # An empty Hash otherwise.
    def key_attributes_from_fields
      attr_map = {}
      required_fields.each do |fld|
        attr_map.merge!({ fld.name => fld.value }) if keys.blank? || keys&.include?(fld.name)
      end
      attr_map
    end

    # Returns the Hash of context names & their corresponding key values, as extracted from all #required_rows,
    # if the #keys filtering array is blank or if some of these context names are included in
    # the filtering list.
    #
    # Assumes #extract() has already been called (or the keys/values will be blank).
    # An empty Hash otherwise.
    def key_attributes_from_rows
      attr_map = {}
      required_rows.each do |ctx|
        attr_map.merge!({ ctx.name => ctx.key }) if keys.blank? || keys&.include?(ctx.name)
      end
      attr_map
    end

    # Returns +true+ if this context has any associated key values
    # (for extracting data) by scanning all its key attributes from
    # both fields and rows.
    #
    # Assumes #extract() has already been called (or the keys/values will be blank).
    # +False+ otherwise.
    def has_key_values?
      key_attributes_from_fields.present? || key_attributes_from_rows.present?
    end

    # Returns the Hash of required [key, value] pairs as extracted from all the siblings
    # (captured format, fields & rows with sub-contexts, all required and possibly filtered by the #keys property).
    #
    # Assumes #extract() has already been called (or the keys/values will be blank).
    # An empty Hash otherwise.
    #
    # == NOTE:
    # +key+ & +key_hash+ may result empty after running format_parser.parse() given
    # +data_hash+ gets reset on page change or after EOF is reached.
    # Rely on ContextDAOs for storing actual keys & data values.
    def key_hash
      return {} unless @data_hash.is_a?(Hash)

      @data_hash.select { |key, _val| keys.blank? || keys&.include?(key) }
    end

    # Returns the composed key value from all the siblings (captured format, fields & rows with
    # sub-contexts, all required and possibly filtered by the #keys property), collated using
    # the specified +separator+.
    #
    # Assumes #extract() has already been called (or the keys/values will be blank).
    # An empty string otherwise.
    #
    # == NOTE:
    # +key+ & +key_hash+ may result empty after running format_parser.parse() given
    # +data_hash+ gets reset on page change or after EOF is reached.
    # Rely on ContextDAOs for storing actual keys & data values.
    def key(separator: '|')
      return '' unless @data_hash.is_a?(Hash)

      key_hash.values.join(separator)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Checks if this ContextDef can be applied to the <tt>row_buffer</tt> array (an array of text lines
    # from a document that needs to be parsed), positioned at <tt>scan_index</tt> from the start
    # of the current document page.
    #
    # All conditions defined by the properties need to be satisfied for the context to be valid
    # (including nested sibling contexts and fields).
    #
    # A ContextDef can also extract data associated with it, each time it is valid. The extracted data
    # will concur in forming this ContextDef key.
    #
    # "Extracting data" from the specified row buffer means repeatedly try to apply the context and
    # extract the captured data each time it is valid.
    #
    # == Params / options:
    # - <tt>row_buffer</tt> => array of Strings representing the current source buffer that has to be parsed.
    #                          Original (source) text documents should be split in pages (at least).
    #
    #                          The <tt>row_buffer</tt> should be a sub-set of rows from the source document and
    #                          it will always be scanned from its 0-index (although it could come from any position
    #                          of the source document, indicated by the current scan_index).
    #
    # - <tt>scan_index</tt> => starting index (0..N), page-relative, used for context filtering in case properties
    #                          like 'at_fixed_row' or 'starts_at_row' have been set to filter out the validation process.
    #
    #                          If the supplied row buffer isn't properly split in lines or has a different granularity,
    #                          for safety it will rejoined with line breaks and then split again to yield an actual
    #                          row buffer of all the individual lines in the original source.
    #
    # - <tt>extract</tt>    => when +true+, a ContextDAO will be filled with the data extracted according to
    #                          this ContextDef. Default: +true+
    #
    # == Returns
    # +true+ if this section/context definition can be applied to the source rows;
    # +false+ otherwise.
    #
    # === Principles:
    # 1. Non-applicable ContextDef (be it, ContextDefs invalid on the current buffer)
    #    shouldn't even be considered for data extraction - but - extracting a non-valid
    #    ContextDef shouldn't raise any errors and just return a nil instead of a ContextDAO
    #    appended to its resulting data list.
    #
    # 2. The passed row_buffer isn't modified when processed (which is the opposite of FieldDefs) but
    #    the scan index is increased of the number of lines processed.
    #
    # 3. Each time valid?() or extract() is run all the internal indexes & results for
    #    this context will be reset (that is, #curr_index, #key, #log, ...).
    #
    # 4. Be advised that when 'extract: false' is used, some logic shortcuts will be applied
    #    to the algorithm and the #key may result empty.
    #    This is most important to know during format/layout detection, which relies on full
    #    key/value extraction beside the simple true/false result.
    #    (In other words, the only way to have a #key filled-in for sure is when extracting data.)
    #
    # == Validity/Extraction steps (in order):
    # 0. Bail-out conditions (scan index outside of range || not at_fixed_row)
    # 1. Buffer rows clipping according to any defined range (page & scan_index -relative)
    # 2. Apply scan index + starts_with / ends_with additional range delimiters
    # 3. Limit resulting buffer to row_span max lines
    # 4. Apply Lambda(s) on each row
    # 5. Check if format is present on collated result, then split it in lines again
    # 6. Fields scan: all required fields must be able to extract data (=> field group is valid)
    # 7. Rows scan: all required sub-contexts must be valid
    #
    # @see also: #extract
    def valid?(row_buffer, scan_index, extract: true)
      @last_validation_result = false
      @curr_index = 0 # Local scan index, relative to the resulting row_buffer, after resizing & limiting
      @consumed_rows = 0
      @data_hash = {}
      log_message(scan_index:)
      # 0) Bail-out conditions:
      # Exit with no extraction & optional or repeatable context (these are always valid)
      if !extract && (optional? || repeat?)
        @last_validation_result = true
        return true
      end

      # Overwrite/recompute starts_at_row if EOP is true:
      curr_buffer = assert_row_buffer_granularity(row_buffer)
      starts_at_row = curr_buffer.count - row_span if eop? # EOP will set "starts_at_row" negative & relative to the row_span

      # Exit when out of range:
      return false if (curr_buffer.count < scan_index - 1) ||
                      (ends_at_row.present? && scan_index >= ends_at_row) ||
                      (at_fixed_row.present? && scan_index != at_fixed_row) ||
                      (starts_at_row.present? && scan_index < starts_at_row)

      # Prepare curr_buffer for the check:
      # == NOTE:
      # At this point, it is always: (scan_index == at_fixed_row) && (starts_at_row >= at_fixed_row)
      # (if both index ranges are defined)

      # 1) Buffer rows clipping if requested & possible (end delimiter first always):
      #    (scan_index is the offset for the properties values)
      local_end = ends_at_row if ends_at_row.present?
      curr_buffer = curr_buffer[..local_end] if curr_buffer.present? && local_end.present?
      # Note that EOP contexts will have a preset starts_at_row already set for the range check
      # that overrides any other starts_at_row prop value. Thus filtering on the current scan_index as done below is enough.
      if curr_buffer.present? && starts_at_row.present? && !eop?
        local_start = starts_at_row
        curr_buffer = curr_buffer[local_start..]
      end
      # DEBUG ----------------------------------------------------------------
      # if name == 'results3_dsq' # && (scan_index >= 64)
      #   log_message(msg: "BEFORE @fields (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   # binding.pry if scan_index >= starts_at_row.to_i
      # end
      # ----------------------------------------------------------------------

      curr_buffer = curr_buffer[scan_index..] if curr_buffer.present?

      # 2) Apply limiting starts_with / ends_with sub-tokens (not regexps).
      #    Re-collate before applying sub-token delimiters:
      curr_buffer = curr_buffer&.join("\r\n")
      if curr_buffer.present? && ends_with.present?
        idx = curr_buffer.index(ends_with)
        curr_buffer = curr_buffer[..idx]
      end
      if curr_buffer.present? && starts_with.present?
        idx = curr_buffer.index(starts_with)
        curr_buffer = curr_buffer[idx..]
      end

      # 3) Force resulting buffer to stay in between row_span lines:
      # (Allows to force max range of looking-forward for matches to #row_span)
      curr_buffer = assert_row_buffer_granularity(curr_buffer)
      curr_buffer = curr_buffer[0..(@row_span - 1)] if curr_buffer.is_a?(Array)

      # 4) Apply any lambda(s) if present:
      log_message(msg: "before @lamdba: #{lambda}", scan_index:, curr_buffer:) if lambda

      if lambda.is_a?(Array)
        lambda.each { |curr_lambda| curr_buffer = apply_lambda(curr_lambda, curr_buffer) }
      elsif lambda.is_a?(String)
        curr_buffer = apply_lambda(lambda, curr_buffer)
      end

      # Re-collate buffer before format:
      curr_buffer = curr_buffer&.join("\r\n")
      @last_source_before_format = curr_buffer&.dup
      log_message(msg: "before @format: #{format}", scan_index:, curr_buffer:) if format
      # DEBUG ----------------------------------------------------------------
      # if name == 'results3_dsq' # && (scan_index == 2)
      #   log_message(msg: "BEFORE @format (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   # binding.pry
      # end
      # ----------------------------------------------------------------------

      # 5) Check & apply format (+strip) if present:
      if format.present?
        # DEBUG ----------------------------------------------------------------
        # if name == 'event' && (scan_index == 2)
        #   log_message(msg: "INSIDE @format, BEFORE empty check (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
        #   binding.pry
        # end
        # ----------------------------------------------------------------------
        # Bail out for expected blank rows:
        # (Let's not bother to apply format in this case 'cos it won't work as blanks aren't supported by #apply_format)
        # Note: the only way to support blank empty lines is to specify the "^$" format.
        if curr_buffer.blank? && format == /^$/i
          # WAS: @curr_index = scan_index = scan_index + 1
          @consumed_rows = 1
          @curr_index += 1
          @last_validation_result = true
          return true
        end
        # DEBUG ----------------------------------------------------------------
        # if name == 'rel_result-row1' # && (scan_index >= 64)
        #   log_message(msg: "INSIDE @format, AFTER empty check (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
        #   binding.pry
        # end
        # ----------------------------------------------------------------------

        curr_buffer = apply_format(curr_buffer)
        if curr_buffer.is_a?(String)
          curr_buffer.strip!
          if curr_buffer.present? # (Add data values when present regardless being required or not)
            @consumed_rows = 1
            @last_validation_result = true
            @data_hash.merge!({ name => curr_buffer })
          end
        end
      end
      # DEBUG ----------------------------------------------------------------
      # if name == 'results3_dsq' # && (scan_index == 2)
      #   log_message(msg: "AFTER @format (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   # binding.pry
      # end
      # ----------------------------------------------------------------------

      # All check must fail if 'optional_if_empty?' is set before returning true in case of emptiness:
      return false if curr_buffer.blank? && !optional_if_empty? &&
                      (format.present? || fields.present? || rows.present?)

      curr_buffer = assert_row_buffer_granularity(curr_buffer)
      if fields
        log_message(msg: "before @fields (tot: #{fields&.count})", scan_index:, curr_buffer:,
                    depth: parent.present? ? 1 : 0)
      end
      # DEBUG ----------------------------------------------------------------
      # if name == 'rel_team2'
      #   log_message(msg: "BEFORE @fields (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   binding.pry
      # end
      # ----------------------------------------------------------------------

      # 6) Fields scan: extract all required data from current row buffer;
      #                 valid <=> all required fields have data
      source_row = curr_buffer.dup
      valid = fields&.all? do |field_def|
        # DEBUG ----------------------------------------------------------------
        # binding.pry if source_row.to_s.include?("(49.01)")
        # ----------------------------------------------------------------------
        source_row = field_def.extract(source_row) if field_def.is_a?(PdfResults::FieldDef)
        log_message(obj: field_def, scan_index:, source_row:, depth: parent.present? ? 2 : 1)

        # Add data values when present regardless being required or not:
        @data_hash.merge!(field_def.name => field_def.value) if field_def.value.present?

        field_def.value.present? || !field_def.required?
      end
      # Update consumed rows:
      @consumed_rows = 1 if valid && key.present?

      # Force valid when fields may not have extracted any key with an empty buffer BUT 'optional_if_empty?':
      if fields.present? && optional_if_empty? && curr_buffer.all? { |r| r.blank? }
        valid = true
        @consumed_rows = 1
      end
      # DEBUG ----------------------------------------------------------------
      # if name == 'event' && (scan_index == 2)
      #   log_message(msg: "AFTER @fields (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   # binding.pry
      # end
      # ----------------------------------------------------------------------
      return false if fields.present? && !valid

      # ** At this point: **
      # - Either fields or format must increase the row scanning index (Because of the default row span: 1)
      # (=> ASSUMES: all fields are on the same line)

      # DEBUG ----------------------------------------------------------------
      # if name == 'footer'
      #   log_message(msg: "BEFORE BEFORE @rows (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}", scan_index: scan_index)
      #   # binding.pry
      # end
      # ----------------------------------------------------------------------

      # Increase scan_index with default row_span if valid w/ fields or when just the format was found:
      if valid && fields.present? # || (format.present? && source_row.present? && valid.nil?)
        # WAS: @curr_index = scan_index + 1
        @curr_index += 1
      end
      if rows
        log_message(msg: "before @rows (tot.: #{rows&.count}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows}",
                    scan_index:, curr_buffer:, depth: parent.present? ? 1 : 0)
      end

      # 7) Rows scan: valid <=> all required rows are valid
      valid = rows&.all? do |sub_context|
        # Ignore invalid rows:
        next unless sub_context.is_a?(PdfResults::ContextDef)

        valid = sub_context.valid?(curr_buffer, @curr_index)
        # DEBUG ----------------------------------------------------------------
        # if sub_context.name == 'results3_dsq' # && (scan_index == 17)
        #   log_message(msg: "IN ROWS, @curr_index: #{@curr_index}", scan_index: scan_index)
        #   # binding.pry
        # end
        # ----------------------------------------------------------------------

        # == "Consume lines only when found":
        # Increase both the local index & the buffer offset for the exact number
        # of consumed lines (only when "actually found"):
        if valid
          @consumed_rows += sub_context.consumed_rows
          @curr_index += sub_context.consumed_rows # + sub_context.curr_index
        end
        log_message(obj: sub_context, scan_index:, depth: sub_context.parent.present? ? 2 : 1)

        # Add data values when present regardless being required or not:
        # (Context 'name' here acts as a key to identify the latest context data-as-key being extracted)
        @data_hash.merge!(sub_context.name => sub_context.key) if sub_context.key.present?

        valid || !sub_context.required?
      end
      # Still valid if rows failed because buffer is all empty but 'optional_if_empty?' is set:
      if rows.present? && !valid && optional_if_empty? && curr_buffer.all? { |r| r.blank? }
        valid = true
        # Increase consumed rows of all the row_span, given optional_if_empty applies
        # to this whole container context:
        @consumed_rows += row_span
      end
      # DEBUG ----------------------------------------------------------------
      # if name == 'event' && (scan_index == 2)
      #   log_message(msg: "AFTER ROWS (#{name}), @curr_index: #{@curr_index}, @consumed_rows: #{@consumed_rows} (BEFORE RETURN)",
      #               scan_index: scan_index, curr_buffer: curr_buffer)
      #   binding.pry
      # end
      # ----------------------------------------------------------------------
      return false if rows.present? && !valid

      # (Re)Set the DAO value whenever there's a (new) valid context found:
      if key.present?
        log_message(msg: "\033[1;33;32mDAO created.\033[0m", scan_index:)
        @dao = ContextDAO.new(self)
      else
        log_message(msg: "\033[1;33;32m✔\033[0m", scan_index:)
      end
      # Set the internal validation result value only when actually found:
      @last_validation_result = true if valid
      true
    end

    # Applies this ContextDef extracting its field values if any (from <tt>row_buffer</tt> starting from <tt>scan_index</tt>)
    # assuming it can be applied and it's valid.
    #
    # Same as #valid?(row_buffer, scan_index, extract: true), but returns already the
    # actual DAO extracted (the #dao member) instead of a simple true/false response.
    #
    # == Params / options:
    # - <tt>row_buffer</tt> => array of Strings representing the portion of the text page that has to be parsed
    #
    # - <tt>scan_index</tt> => starting index (0..N) for scanning the row_buffer
    #
    # == Returns
    # The resulting ContextDAO storing all data extracted from the specified <tt>row_buffer</tt>,
    # starting from its <tt>scan_index</tt> row.
    #
    # @see #valid?
    def extract(row_buffer, scan_index)
      valid?(row_buffer, scan_index, extract: true) ? @dao : nil
    end
    #-- -----------------------------------------------------------------------
    #++

    # Debug helper: scans the given +list+ (an Array of ContextDefs) preparing a
    # (sub-)hierarchy printable string tree, using ctx as the starting point of the hierarchy,
    # seeking all its declared siblings in the list, in breadth-first mode.
    #
    # The +list+ typically is the list extracted from a YML format file
    # for the FormatParser.
    # (From 'format_parser.format_defs.values' after a single #parse() call, which fills the #format_defs)
    #
    # Returns a printable ASCII (string) tree of the context hierarchy.
    def hierarchy_to_s(list:, ctx: self, output: '', depth: 0) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      output = if output.blank? && depth.zero?
                 "\r\n(#{ctx.parent.present? ? ctx.parent.name : '---'})\r\n"
               else
                 ('  ' * depth) << output
               end
      output << ('  ' * (depth + 1)) <<
        "+-- #{ctx.name}#{ctx.has_key_values? ? '🔑' : ''}" <<
        "#{ctx.required? ? '🔒' : ''}" <<
        "#{ctx.repeat? ? '🌀' : ''}\r\n"

      if ctx.rows.present?
        output << ('  ' * (depth + 2)) << "  [:rows]\r\n"
        ctx.rows.each do |sub_ctx|
          output = hierarchy_to_s(list:, ctx: sub_ctx, output:, depth: depth + 3)
        end
      end

      # Select only direct siblings from the list of available contexts and
      # add them to the sub-tree (while handling also parent-as-strings special case):
      list.select { |ctx_item| ctx_item.parent.is_a?(ContextDef) ? ctx_item.parent&.name == ctx.name : ctx_item.parent == ctx.name }
          .each do |sibling_ctx|
            output = hierarchy_to_s(list:, ctx: sibling_ctx, output:, depth: depth + 2)
          end

      output
    end

    # Debug helper: converts instance contents into a viewable string representation, with a list of active properties.
    def to_s
      offset = parent.present? ? "\t" : ''
      output = "\r\n#{offset}[#{self.class.name.split('::').last} <#{name}>]\r\n"
      output << "|=> '#{key}'\r\n" if key.present?
      ALL_PROPS.each do |prop_key|
        next if prop_key == 'name' # (Don't output the name twice)

        next unless instance_variable_defined?(:"@#{prop_key}")

        raw_val = instance_variable_get(:"@#{prop_key}")
        prop_val = if raw_val.is_a?(String)
                     "\"#{raw_val}\"\r\n"
                   # Output just the name for sub-contexts:
                   elsif raw_val.is_a?(ContextDef)
                     "<#{raw_val.name}>\r\n"
                   # Add carriage return for array of lambdas:
                   elsif prop_key == 'lambda' && raw_val.present?
                     "#{raw_val}\r\n"
                   # Map any other list into a collated string:
                   elsif raw_val.is_a?(Array) && raw_val.present?
                     raw_val.map { |i| i.to_s }.join
                   # Default output (raw value with carriage return):
                   else
                     "#{raw_val}\r\n"
                   end
        output << "#{offset}- #{prop_key.ljust(13, '.')}: #{prop_val}" if prop_val.present?
      end

      output
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # Formats & adds +msg+ to the internal log, adding a carriage return at the end.
    # == Options:
    # - scan_index  => (required) current buffer scanning index (0..N, inside curr_buffer)
    # - msg         => String message to be added to the log; can be nil (default) to just output the context name and the scanning index
    # - curr_buffer => current string buffer; can be nil (default) to skip logging of its details
    # - obj         => instance subject for the log message, either a FieldDef or a ContextDef or nil (default) to skip this output
    # - source_row  => source string row subject to the scan: usually a subset of rows of curr_buffer or nil (default) to skip output
    # - depth       => log indentation depth for better visual formatting; default: 0
    def log_message(scan_index:, msg: nil, obj: nil, curr_buffer: nil, source_row: nil, depth: 0)
      indentation = "\t".ljust(depth, "\t")
      formatted = nil

      if source_row && obj.is_a?(FieldDef)
        formatted = Kernel.format("%s🔹 FIELD '\033[1;33;34m%s\033[0m'\r\n%s   source_row (size: %d) <<%s>>\r\n",
                                  indentation, obj.name, indentation, source_row.size, source_row) +
                    Kernel.format("%s   '%s' => '\033[1;33;36m%s\033[0m' %s",
                                  indentation, obj.name.ljust(15, '.'), obj.value, result_icon_for(obj))
      elsif obj.is_a?(ContextDef)
        formatted = Kernel.format("%s🔸 SUB-CTX [\033[1;33;37m%s\033[0m] => %s -- curr_index: %d, consumed_rows: %d, row_span: %d",
                                  indentation, obj.name, result_icon_for(obj), obj.curr_index.to_i, obj.consumed_rows.to_i, obj.row_span.to_i)
      elsif msg.blank?
        formatted = Kernel.format('%s🔎 [%s] %s%s -- scan_index: %03d, curr_index: %d, consumed_rows: %d, row_span: %d',
                                  indentation, name, repeat? ? '🌀' : '', required? ? '🔑' : '', scan_index,
                                  @curr_index.to_i, @consumed_rows.to_i, @row_span.to_i)
        formatted += Kernel.format(' curr_buffer: <%s>', curr_buffer[0..160]) if curr_buffer
      else
        formatted = Kernel.format('%s   [%s] 👉 %s', indentation, name, msg)
        if curr_buffer
          sub_indent = indentation + ' '.rjust(name.length + 6)
          buff = curr_buffer.is_a?(Array) ? curr_buffer.join("↩\r\n#{sub_indent}") : curr_buffer
          formatted += Kernel.format(" - curr_buffer (%s) size: %d\r\n%s<%s>", curr_buffer.class,
                                     curr_buffer&.size, sub_indent, buff)
        end
      end

      @logger&.debug(formatted)
      Rails.logger.debug(formatted) if @debug
    end

    # Returns a string representation of the type of result stored by the specified
    # FieldDef or a ContextDef. Usable for logging.
    def result_icon_for(obj)
      return "\033[1;33;31m⚠\033[0m" unless obj.is_a?(FieldDef) || obj.is_a?(ContextDef)
      return "\033[1;33;33m~\033[0m" if !obj.required? && !((obj.is_a?(ContextDef) && obj.last_validation_result) || obj.key.present?)
      return "\033[1;33;32m✔\033[0m" if obj.key.present? || (obj.is_a?(ContextDef) && obj.last_validation_result)

      "\033[1;33;31m✖\033[0m"
    end

    # Makes sure the specified row_buffer is split in individual rows intercepting any "\n" in between
    # and returning an Array of strings with no carriage returns in it.
    def assert_row_buffer_granularity(row_buffer)
      row_buffer = row_buffer.join("\r\n") if row_buffer.is_a?(Array)
      if row_buffer.to_s.ends_with?("\n")
        row_buffer.split(/\r?\n/) << ''
      else
        row_buffer.to_s.split(/\r?\n/)
      end
    end
  end
end
