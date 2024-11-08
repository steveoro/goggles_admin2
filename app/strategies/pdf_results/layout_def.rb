# frozen_string_literal: true

module PdfResults
  # = PdfResults::LayoutDef
  #
  #   - version:  7-0.7.24
  #   - author:   Steve A.
  #
  # Stores the parsing context layout definition for a single page,
  # compiled from a parsing layout format YML file.
  #
  # It holds a tree of ContextDef objects, each one representing a single
  # context definition, and its children contexts.
  #
  # During the parsing process, a LayoutDAO object is compiled for each page using
  # the tree of ContextDef objects for recognizing the layout.
  #
  # Successfully parsed pages will yield a LayoutDAO object to be merged with the others.
  #
  class LayoutDef # rubocop:disable Metrics/ClassLength
    # File path of the YAML definition file used to build this instance.
    attr_reader :yaml_filepath

    # Format name (as read from the YAML definition file).
    attr_reader :name

    # Last valid? result; set to false upon each #valid? call.
    attr_reader :last_validation_result

    # Last "external" scanning index set by a #valid?() call on the Context_Def in this layout.
    attr_reader :last_scan_index

    # Current progress index in scanning for this layout, 0..N relative a single text page buffer
    attr_reader :curr_index

    # Hash list of {#ContextDef} instances that compose the layout (keyed by context name).
    attr_reader :context_defs

    # Hash list of aliased {#ContextDef}s (keyed by context name); each alias can substitute a required but missing context,
    # generating layout alternatives within a single definition file.
    attr_reader :aliased_defs

    # Hash for keeping track of repeatable checks (keyed by context name)
    attr_reader :repeatable_defs

    # Array of {#ContextDef} names representing the requested format parsing order.
    attr_reader :format_order

    # Array collection of {#ContextDAO} instances extracted from the same layout.
    attr_reader :page_daos

    # WIP: NEEDED HERE?
    # Hash results from latest valid scan.
    attr_reader :valid_scan_results

    #-- -----------------------------------------------------------------------
    #++

    # Creates a new LayoutDef instance.
    #
    # == Params:
    # - <tt>yaml_filepath</tt> => the YAML file defining this layout.
    #
    # == Additional Options:
    # - <tt>:logger</tt> => a valid Logger instance for debug output. Default: +nil+ to skip logging.
    #
    # - <tt>:debug</tt> => (default +false+) when +true+ the log messages will also
    #   be redirected to the Rails logger as an addition to the +logger+ specified above.
    #
    def initialize(yaml_filepath, logger: nil, debug: false)
      raise 'Invalid LayoutDef specified!' unless layout_def.is_a?(LayoutDef)

      @yaml_filepath = yaml_filepath
      @logger = logger if logger.is_a?(Logger)
      @debug = [true, 'true'].include?(debug) # (default false for blanks)
      prepare_context_defs_from_file

      # # Collect all fields from any root-level field group and from sub-area context rows
      # # (using the sub-context DAOs #fields_hash directly):
      # @fields_hash = {}
      # if context&.fields.present?
      #   context.fields.each { |fd| @fields_hash.merge!({ fd.name => fd.value }) if fd.is_a?(FieldDef) }
      # end
      # return if context&.rows.blank?

      # # Include only data from rows which name is included in the ContextDef data_hash keys:
      # context.rows.each do |ctx|
      #   @fields_hash.merge!(ctx.dao.fields_hash) if ctx.is_a?(ContextDef) && context.data_hash.key?(ctx.name) && ctx.dao.present?
      # end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Resets *all* previously collected data for any ContextDefs included in this instance.
    def clear_data!
      init_scan_pointers
      return unless @context_defs.is_a?(Hash)

      @context_defs.each_value { |ctx| ctx.clear_data if ctx.respond_to?(:clear_data) }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Raises a runtime error in case the specified context index or name isn't valid.
    # (Assumes index to be a number and name to be a string)
    def validate_context!(ctx_index_or_name)
      # Prevent nil contexts & signal format def error:
      existing = (ctx_index_or_name.is_a?(String) && @context_defs.key?(ctx_index_or_name)) ||
                 (ctx_index_or_name.present? && @format_order.at(ctx_index_or_name).present?)
      return if existing

      msg = 'Invalid context name or index referenced as parent!'
      log_message("\r\n#{msg}")
      caller.each { |trace| log_message(trace) }
      raise msg.to_s
    end

    # Returns the previous context or nil if not available.
    # Note that if ctx_index is zero, the previous context will be the last one (array indexes wrap up only backwards).
    def prev_context(ctx_index)
      @context_defs.fetch(@format_order.at(ctx_index - 1), nil)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans @aliased_defs in search for the right key name.
    # Returns the original context name of an aliased ContextDef.
    # Returns nil otherwise.
    def find_ctx_name_from_alias(alias_ctx_name)
      return unless @aliased_defs.is_a?(Hash)

      key_name, _aliases = @aliased_defs.find { |_key, aliases| aliases&.include?(alias_ctx_name) }
      key_name
    end

    # Returns the unaliased context name if the specified name is an alias.
    # Returns the same context name otherwise.
    def unaliased_ctx_name(ctx_name)
      unaliased_name = find_ctx_name_from_alias(ctx_name)
      return ctx_name if unaliased_name.blank?

      unaliased_name
    end

    # Returns the parent ContextDef instance when the parent property is properly set.
    # Searches for an existing, unaliased name whenever the property value is still set to a
    # string (parent ContextDef defined  after the sibling in the format file).
    # Returns +nil+ when not found or if the parent property wasn't set.
    def find_unaliased_parent_context_for(context_def)
      return if context_def.parent.blank?
      return @context_defs.fetch(unaliased_ctx_name(context_def.parent), nil) if context_def.parent.is_a?(String)

      context_def.parent
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns true if the specified context_def name has already been verified with a
    # run at this same row_index. False otherwise.
    # === Note:
    # The idea is to avoid infinite loops without using recursion: we need to streamline the loops
    # and avoid checking rows or extracting from rows more than once if already done, independently
    # from the actual result.
    def check_already_made?(context_name, row_index)
      # "Repeatables" can be re-checked indefinitely but not on the same line:
      return true if @repeatable_defs.key?(context_name) && (@repeatable_defs[context_name].fetch(:last_check, nil) == row_index)

      # Retrieve the context by name and check its #last_scan_index:
      context_def = @format_defs.fetch(context_name, nil)
      return false unless context_def.is_a?(ContextDef)

      # Return true if the context has already been scanned on the same line:
      context_def.last_scan_index == row_index
    end

    # Relies on @valid_scan_results to store the result of the scan for a specific context name.
    # Returns +true+ if all *required* contexts defined in @format_defs have been satisfied.
    def all_required_contexts_valid?(format_name)
      @format_defs.all? do |ctx_name, ctx|
        ctx.required? ? @valid_scan_results.key?(format_name) && @valid_scan_results[format_name].key?(ctx_name) && @valid_scan_results[format_name][ctx_name] : true
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Adds +msg+ to the internal log. If @debug was set to true, also prints it to the Rails logger.
    # == Params
    # - msg: String message to be added to the log
    def log_message(msg)
      @logger&.debug(msg)
      Rails.logger.debug(msg) if @debug
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # Resets the internal scanning pointers & counters.
    def init_scan_pointers
      @last_validation_result = nil
      @last_scan_index = 0
      @curr_index = 0
    end

    # Resets the result members and prepares the @context_defs Hash for scanning
    # the source document page or pages.
    #
    # === Clears and prepares:
    # - result_format_type
    # - context_defs
    # - repeatable_defs
    # - format_order
    # - page_daos (because each page is assumed to have only 1 format)
    #
    # This allows #parse() to work with single formats page-by-page until detection
    # for the same format fails, while also collecting DAOs even when resuming scan
    # with a different format file.
    #
    # == Returns:
    # The string format #name usable as key for this format type.
    #
    def prepare_context_defs_from_file # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      layout_def = YAML.load_file(@yaml_filepath)
      @name = layout_def.keys.first
      init_scan_pointers
      context_props_array = layout_def[@name]

      # Init result variables:
      # @result_format_type = nil # chosen & valid format type (FIFO)

      # Actual scan result (keyed by format name & sub-keyed by ContextDef type-name);
      # @valid_scan_results = { @name => {} } # (This should reset on every page change)
      # @valid_scan_results = {}  # (This should reset on every page change)

      @context_defs = {}        # Hash list of ContextDefs
      @aliased_defs = {}        # Hash list of aliased ContextDefs
      @repeatable_defs = {}     # Hash for keeping track of repeatable checks (keyed by context name)
      @format_order = []        # requested format order
      @page_daos = []           # Collection of DAOs found on current page
      # NOTE: page DAOs are cleared on each page break and stored
      #       into @root_dao only if the current overall format is successful

      context_props_array.each do |context_props|
        # Set ContextDef alias list when present:
        if context_props['alternative_of'].present? && context_props['alternative_of'].is_a?(String)
          @aliased_defs[context_props['alternative_of']] ||= []
          @aliased_defs[context_props['alternative_of']] << context_props['name']
        end

        # Set proper parent reference:
        # (ASSUMES: parent context must be already defined; when the parent is an
        #  alias for another context, the original must be used;
        #  when not yet defined, the parent will remain a string key instead of being
        #  converted into a Context)
        if context_props['parent'].present? && context_props['parent'].is_a?(String)
          parent_name = unaliased_ctx_name(context_props['parent'])
          parent_ctx = @context_defs.fetch(parent_name, nil)
          context_props['parent'] = parent_ctx if parent_ctx
        end
        context_def = ContextDef.new(context_props.merge(logger: @logger, debug: @debug))
        @context_defs[context_def.name] = context_def
        @repeatable_defs[context_def.name] = {} if context_def.repeat?
        @format_order << context_def.name
      end

      @name
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the new row_index value given the #valid?() check result & the current context_def
    # for the scan.
    # Updates also the #valid_scan_results hash with the valid?() response.
    # Returns the unmodified row_index if a key value wasn't extracted.
    def progress_row_index_and_store_result(row_index, valid_result, format_name, context_def)
      # Memorize last check made when the def can be checked on multiple buffer chunks:
      if context_def.repeat?
        # DEBUG
        # $stdout.write("\033[1;33;30mr\033[0m") # Signal "Repeatable check update"
        @repeatable_defs[context_def.name] ||= {}
        @repeatable_defs[context_def.name][:last_check] = row_index
        @repeatable_defs[context_def.name][:valid] = valid_result
        @repeatable_defs[context_def.name][:valid_at] ||= []
        @repeatable_defs[context_def.name][:valid_at] << row_index if valid_result && @repeatable_defs[context_def.name][:valid_at].exclude?(row_index)
      end

      # Prepare a scan result report, once per context name:
      # (shouldn't overwrite an already scanned context on a second FAILING pass)
      @valid_scan_results[format_name][context_def.name] = valid_result if @valid_scan_results[format_name][context_def.name].blank?

      # "Stand-in" for another context if this is an "alternative_of" and ONLY when VALID:
      if context_def.alternative_of.present? && valid_result &&
         @valid_scan_results[format_name][context_def.alternative_of].blank?
        @valid_scan_results[format_name][context_def.alternative_of] = valid_result
      end
      return row_index unless valid_result && context_def.consumed_rows.positive?

      parent_ctx = find_unaliased_parent_context_for(context_def)

      # Un-alias current DAO before storage:
      actual_dao = context_def.dao
      # DEBUG ----------------------------------------------------------------
      # binding.pry if valid_result && context_def.key.include?('BRIGHENTI Maurizio')
      # ----------------------------------------------------------------------

      if actual_dao.present? && context_def.alternative_of.present?
        unaliased_ctx = @context_defs.fetch(context_def.alternative_of, nil)
        raise "'alternative_of' context set but original context not found when storing data: check your .yml layout definition file!" if unaliased_ctx.blank?

        unaliased_ctx.prepare_dao(context_def)
        actual_dao = unaliased_ctx.dao
      end

      # *** Store data: ***
      # case 1) parent is set => add DAO to parent rows:
      if actual_dao.present? && parent_ctx.present? && parent_ctx.dao.present?
        # (Handle aliases) Force parent preparation so that if we're
        # dealing with an aliased parent which is still "blank" we will store the
        # current DAO in the actual parent even if its alias passed the valid? check
        # while the original didn't:
        parent_ctx.prepare_dao if parent_ctx.dao.blank?
        parent_ctx.dao.add_row(actual_dao)

      # case 2) no parents => DAO goes to current "page root":
      elsif actual_dao.present?
        @page_daos << actual_dao
        # (ELSE: don't append empties unless there's an actual DAO)
      end

      # DEBUG
      # $stdout.write("\033[1;33;30mC\033[0m") # Signal "Consumed rows"
      # Consume the scanned row(s) if found:
      row_index + context_def.consumed_rows

      # === NOTE:
      # Some ContextDef may define some rows or fields as NOT required.
      # So, for ex., while row_span may be 3 with 1 optional row, curr_index
      # will be 2 if the optional row hasn't been found.
      # The page-relative row_index must be increased of ONLY the actual number of rows
      # properly validated.
      #
      # See app/strategies/pdf_results/formats/1-ficr1.100m.yml format for an actual example:
      # if the row_index is increased always of the row_span, some misalignment may occur when
      # parsing results that can span a max of 3 rows but most of the times they occupy just 2.
    end
  end
end
