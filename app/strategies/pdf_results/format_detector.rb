# frozen_string_literal: true

module PdfResults
  # = PdfResults::FormatDetector strategy
  #
  #   - version:  7-0.5.22
  #   - author:   Steve A.
  #
  # Given the whole first page of a text file this strategy class will try to detect
  # which known layout format the text file belongs to.
  #
  class FormatDetector
    attr_reader :first_page, :rows, :result, :curr_dao, :named_context

    # Creates a new strategy given the first text page (as a String) from the data source
    # that has to be analyzed.
    def initialize(first_page)
      @first_page = first_page
      @rows = first_page&.split("\n")
      @result = @curr_dao = nil
    end
    #-- -----------------------------------------------------------------------
    #++

    # Detects & returns which known layout format the data file belongs to.
    # Sets the +result+ with the name/key of the first matching format found for the
    # first page specified in the constructor.
    #
    # Returns +nil+ when unknown or in case of errors.
    def parse
      return unless @rows.present?

      # Collect all defined format layouts:
      format_defs = {}
      Dir.glob(Rails.root.join('app/strategies/pdf_results/formats/*.yml')).each do |format_file|
        format_defs.merge!(YAML.load_file(format_file))
      end

      format_defs.each do |name, format_def|
        puts "\r\n--- 🩺 Checking '#{name}' ---"
        # Reset data, context, source idx & checks:
        @parent_name = nil # parent context name
        @context_name = 'header'
        @result = @curr_dao = ContextDAO.new(key: @context_name)
        @named_context = {}
        @columns = {}
        @format_ok = true
        @repeatable_lambdas = [] # Needed?

        # TODO: progress in @line_index only at end
        # - repeat until @line_index reaches end of data page
        # - must keep a list of satisfied conditions in format_def
        # - format_def fails only at end of a full format_def loop, if there are some failed conditions
        # - the bail-out conditions must prevent useless parsing when not in context

        # - after a first successful parsing, make sure the structure is easily convertible to the JSON FIN-layout for data import
        # - Refactor using a DAO with a #to_json helper for ease of serialization

        # For each source row:
        @rows.each_with_index do |curr_row, line_index|
          break unless @format_ok

          printf("\r\n==> LINE %04d\r\n", line_index)
          # Scan each def. row:
          format_def.each_with_index do |lambda_hash, def_index|
            next unless lambda_hash.present? # Skip empty nodes (due to syntax errors)

            @format_ok = analyze_curr_line(lambda_hash, def_index, curr_row, line_index)
            break unless @format_ok
          end
        end

        # TODO: @format_ok here signals failure of the curr format_def
        # - if @format_ok, must repeat the loop until @line_index reaches the end of the page to complete the parsing
        #   and process any repeatable lambdas (should bail out automatically from those not applicable)
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # *Lambda action*: matches the specified value inside <tt>curr_row</tt>.
    #
    # === Successful match:
    # Value is found and starts with _at_least_ a space.
    def spaced(curr_row, value)
      curr_row.present? && value.present? && (curr_row =~ /^\s+/) && curr_row.include?(value)
    end

    # *Lambda action*: matches the specified value inside <tt>curr_row</tt>.
    #
    # === Successful match:
    # Value is found and is at the beginning of the row.
    def starts_with(curr_row, value)
      curr_row.present? && value.present? && curr_row.starts_with?(value)
    end

    # *Lambda action*: matches all field names as a single header row, assuming variable spacing.
    #
    # === Successful match:
    # All column names are found, regardless of spacing.
    def data_columns(curr_row, col_defs)
      return unless curr_row.present? && col_defs.is_a?(Array) && col_defs.present?

      # Compose & match the header, ignoring spacing between the columns:
      col_names = col_defs.map{ |h| h.keys.first }
      reg = Regexp.new('^\s*' + col_names.join('\s+'), Regexp::IGNORECASE)
      return false unless curr_row =~ reg

      # Set column titles => format:
      col_defs.each { |col_def| @columns[col_def.keys.first] = col_def.values.first }
      true
    end
    #-- -----------------------------------------------------------------------
    #++

    # *Lambda action*: extracts the specified field name from <tt>curr_row</tt>.
    #
    # === Successful match:
    # Extracted field value, stripped of spaces, is still present.
    def field_spaced(curr_row, field_name)
      return unless curr_row.present? && field_name.present?

      field_value = curr_row.strip
      # Detect possible change of context and set "possible new context"
      # flag with field name when true:
      @possible_new_context_name = field_name if @new_context &&
                                                (@curr_dao.key != field_name || @curr_dao.value != field_value)
      # DEBUG ----------------------------------------------------------------
      binding.pry if field_name == 'category' #&& @possible_new_context_name.present?
      # ----------------------------------------------------------------------
      check_named_context(field_name, field_value, @parent_name)

      # Add extracted field only to current context DAO:
      @curr_dao.add_field(field_name, field_value)
      field_value.present?
    end

    # *Lambda action*: extracts all column fields from <tt>curr_row</tt> using the array of formats
    # for each column, stored in the <tt>@columns</tt> member.
    #
    # === Successful match:
    # Usually successful, even when a bunch of columns are empty.
    # Returns +nil+ only if @columns is not set or the current row or the extracted item hash are empty.
    def field_data_columns(curr_row)
      return unless curr_row.present? && @columns.present?

      # Extract all possible columns assuming each is separated by at least a couple of spaces:
      data_tokens = curr_row.split(/\s{2,}/)
      item_hash = {}  # new row container

      # Scan each destination column field for format matches and extract the column data:
      @columns.each do |col_name, col_format|
        curr_token = data_tokens.shift
        next if col_format.blank?

        reg = Regexp.new(col_format, Regexp::IGNORECASE)
        matches = reg.match(curr_token)
        col_value = matches.captures.first if matches.is_a?(MatchData)
        item_hash.merge!(col_name => col_value) if col_value.present?
      end

      @curr_dao.add_item(item_hash) if item_hash.present?
      item_hash.present?
    end
    #-- -----------------------------------------------------------------------
    #++

    # *Lambda action*: starts a new named context if the current line counter is <= <tt>row_count</tt>
    # from the end of <tt>@first_page</tt> (in absolute line length, so 1..N).
    #
    # This is a repeatable check by default. Check fails only if not optional and not found when
    # max page length is reached and the context is not found.
    #
    # Successful named context switch: index >= page length - row_count.
    #
    def eop(curr_row, line_index, row_count)
      # TODO: lambda key L1 check
      if line_index >= @rows.length - row_count
        @possible_new_context_name = 'eop' if @new_context &&
                                              (@curr_dao.key != 'eop' || @curr_dao.value != row_count)
        check_named_context('eop', row_count, @curr_dao.key)

        # TODO: optional (ignore?)
        # TODO: check startswith (ignore?)
        # TODO: extract remainder from start until EOLN with split
      end
    end

    # *Lambda action*: check that the last row of <tt>@first_page</tt> has the expected format.
    # Successful match: value is found according to properties.
    def last_row(curr_row, line_index)
      # TODO: lambda key L1 check
      if line_index >= @rows.length
        @possible_new_context_name = 'eof' if @new_context &&
                                              (@curr_dao.key != 'eof' || @curr_dao.value != line_index)
        check_named_context('eof', line_index, @curr_dao.key)
        # TODO: check sibling lambdas in properties.
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # Checks the current context parameters to detect a possible context change.
    # Returns the updated current context, adding a reference to the internal lookup table when missing.
    #
    # ASSUMES: @curr_dao always defined.
    #
    def check_named_context(new_context_type, new_context_value, parent_context_type = nil)
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------
      # 0. Possible (implied) context change? Bail out if it doesn't:
      return @curr_dao if @possible_new_context_name.blank? ||
                          (@curr_dao.key == new_context_type && @curr_dao.value == new_context_value)

      # 1. Retrieve referenced DAO context by (key, value)
      @context_name = new_context_type # Always set current context type name
      existing_ref = @named_context.fetch(new_context_type, {}).fetch(new_context_value, {}) || {}

      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------
      # 2. Existing DAO found => change curr DAO context to existing one & return
      if existing_ref.is_a?(PdfResults::ContextDAO)
        @curr_dao = existing_ref
        return @curr_dao
      end

      parent_ref = nil
      # 3. Existing DAO not found & parent type not given?
      if parent_context_type.blank?
        #   3.1 Set parent context from curr_dao (use curr_dao itself if it's root node when parent is nil):
        parent_ref = @curr_dao.parent.is_a?(PdfResults::ContextDAO) ? @curr_dao.parent : @curr_dao

      # 3. Existing DAO not found but parent name given?
      else
        #   3.2 Find parent context type in refs
        #       NOTE: parent context reference by type & value NOT supported, and parent context will be chosen as LIFO
        #             (assuming last defined context was actual container)
        parent_ref = @named_context.fetch(parent_context_type, {}).values&.last
        #    3.2.1 Parent context type NOT found?
        #      3.2.1.1 => Format def ERROR: unable to find referenced parent context => abort
        raise("Format Def. Error: cannot find referenced parent context '#{parent_context_type}'") unless parent_ref.is_a?(PdfResults::ContextDAO)
      end

      # 4 Parent context type found & set as curr_dao? Check validity:
      raise("Format Def. Error: cannot find implied parent context") unless parent_ref.is_a?(PdfResults::ContextDAO)

      #   4.1 Add new context to curr_dao, going deeper in hierarchy:
      @curr_dao = parent_ref.add_context(new_context_type, new_context_value)
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------

      # 5. Store new current context DAO inside named references:
      @named_context[new_context_type] ||= {}
      @named_context[new_context_type].merge!(new_context_value => @curr_dao) unless @named_context[new_context_type].key?(new_context_value)
      @curr_dao
    end
    #-- -----------------------------------------------------------------------
    #++

    # Checks the current format context definition present in <tt>lambda_hash</tt>
    # against the source row taken at <tt>line_index<tt> to verify if it's applicable
    # or not.
    #
    # If the context name extracted from the current lambda implies a context change,
    # the current context will be changed accordingly.
    #
    # === Updates:
    # - @context_name
    # - @curr_dao
    # - @named_contexts (?)
    # - @repeatable_lambdas (?)
    #
    # == Returns
    # +true+ if the format is valid and applicable, +false+ otherwise.
    #
    def analyze_curr_line(lambda_hash, def_index, curr_row, line_index)
      lambda_key = lambda_hash.keys.first
      lambda_val = lambda_hash.values.first
      prop_keys = lambda_hash.keys[1..]
      prop_vals = lambda_hash.values[1..]
      applicable = true

      # Extract node def properties:
      # repeat_each_page = property_bool('repeat_each_page', prop_vals, prop_keys) # repeat check once each page
      repeat           = property_bool('repeat', prop_vals, prop_keys)           # repeat check every line
      optional         = property_bool('optional', prop_vals, prop_keys)

      only_before_row = property_int('only_before_row', prop_vals, prop_keys)
      only_from_row   = property_int('only_from_row', prop_vals, prop_keys)
      at_fixed_row    = property_int('at_fixed_row', prop_vals, prop_keys) || def_index # when missing, assumes expected at == def_index
      at_fixed_row    = nil if repeat # clear "fixed row" constraint for "repeatables anywhere"

      @new_context = property_bool('named_context', prop_vals, prop_keys)
      @parent_name = property_raw('parent', prop_vals, prop_keys)
      @possible_new_context_name = nil # default

      # Bail out conditions for current lambda node (skip node when conditions aren't met and repeat check on next loop):
      return true if (only_before_row.present? && line_index >= only_before_row) ||
                     (at_fixed_row.present? && line_index != at_fixed_row) ||
                     (only_from_row.present? && line_index < only_from_row)

      field_name = extract_field_name(lambda_val)

      #   @context_name = field_name
      #   # TODO: Handle 'parent' reference
      #   # TODO: 1. using parent name, get parent reference: scan @named_contexts for parent name and get FIFO
      #   # TODO: 2. use retrieved parent context instead of @curr_dao
      #   # DEBUG ----------------------------------------------------------------
      #   # binding.pry
      #   # ----------------------------------------------------------------------
      # end
      printf("- %03d [%s] #{lambda_key} => #{lambda_val.to_s.truncate(40)} > ", def_index, @context_name)

      ########################################## WIP useful?
      # => repeat IS automatic
      # TODO: distinguish between repeat_each_page @ certain line
      #       & repeat: true, which should nullify at_fixed_row
      # if repeat_each_page # Repeatable check?
      #   @repeatable_lambdas << lambda_hash
      # end

      # Field extraction:
      if field_name.present?
        print('FIELD ')
        # Special case: data_columns value extraction, with format for each column
        if lambda_key == 'data_columns'
          field_data_columns(curr_row) # Never false
        else
          applicable = send("field_#{lambda_key}", curr_row, field_name) if respond_to?("field_#{lambda_key}")
        end

      elsif lambda_key == 'eop' # End of Page special context change
        # TODO / WIP
        eop(curr_row, line_index, lambda_val)

      elsif lambda_key == 'last_row'
        # TODO / WIP
        last_row(curr_row, line_index)

      # "Simple" value match:
      else
        print 'matching '
        applicable = send(lambda_key, curr_row, lambda_val) if respond_to?(lambda_key)
      end

      # Display status of the check only if the check was done & was required:
      if applicable
        print("\033[1;33;32m✔\033[0m\r\n")
      elsif !applicable && !optional && !repeat
        print("\033[1;33;31m✖\033[0m\r\n")
      elsif optional
        print("\r\n")
      end

      applicable || optional || repeat
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the field name specified in between angular brackets or +nil+ otherwise.
    def extract_field_name(lambda_val)
      return unless lambda_val.present? && lambda_val.is_a?(String) && lambda_val[0] == '<' && lambda_val[-1] == '>'

      lambda_val[1..-2]
    end

    # Extracts the property value for <tt>prop_name</tt> assuming it will be any valid serializable object,
    # or +nil+ when not present at all.
    #
    # == Params
    # - prop_name: property string name
    # - prop_keys: array of properties as string keys
    # - prop_vals: array of property values
    #
    # == Returns
    # The value "as is" (without any conversion); +nil+ when not found.
    # Note that this will work even for a serialized Array of values; typical example: 'format'.
    #
    def property_raw(prop_name, prop_vals, prop_keys)
      return unless prop_name.present? && prop_vals.present? && prop_keys.present? && prop_keys.respond_to?(:index) && prop_vals.respond_to?(:at)

      prop_vals.at(prop_keys.index(prop_name)) if prop_keys.index(prop_name).present?
    end

    # Extracts the property value for <tt>prop_name</tt> assuming it will be either 'true' or 'false',
    # or +nil+ when not present at all.
    #
    # == Params
    # - prop_name: property string name
    # - prop_keys: array of properties as string keys
    # - prop_vals: array of property values
    #
    # == Returns
    # +true+ if the value is found equal to 'true' (as string), or +false+ otherwise; +nil+ when not found.
    #
    def property_bool(prop_name, prop_vals, prop_keys)
      result = property_raw(prop_name, prop_vals, prop_keys)
      result.present? && (result == true || result == 'true')
    end

    # Extracts the property value for <tt>prop_name</tt> assuming it will be a valid integer,
    # or +nil+ when not present at all.
    #
    # == Params
    # - prop_name: property string name
    # - prop_keys: array of properties as string keys
    # - prop_vals: array of property values
    #
    # == Returns
    # The value found converted to int; +nil+ when not found.
    #
    def property_int(prop_name, prop_vals, prop_keys)
      result = property_raw(prop_name, prop_vals, prop_keys)
      result.to_i if result.present?
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
