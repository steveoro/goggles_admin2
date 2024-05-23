# frozen_string_literal: true

module PdfResults
  # = PdfResults::FormatParser strategy
  #
  #   - version:  7-0.7.10
  #   - author:   Steve A.
  #
  # Given at least a single whole page of a text file, this strategy class will try to detect
  # which known layout format the text file belongs to.
  #
  # Scans all existing YAML format files stored at 'app/strategies/pdf_results/formats'.
  # Each file is assumed to contain a list of valid ContextDef properties definitions.
  # First format file definition found valid & satisfied wins.
  #
  #
  # === Format files, families of format files and subformats
  #
  # Sub-format files are normal format files belonging to the same "family of formats" and with
  # a common shared ancestor. Sub-formats have a suffix appended just after the shared part
  # of the name of the "main" ancestor format (which is assumed to have the format family name):
  #
  #   "<MAIN_FORMAT_FAMILY_NAME>.<SUBFORMAT>.yml"
  #
  # During layout detection, the FormatParser will load all format (and subformat) files found.
  # When a format "wins" the detection, all formats with a name that includes the same detected
  # family name will be kept and iteratively checked, page-by-page.
  #
  # This allows us to parse multi-format files as long as the format change happens at
  # page start.
  #
  # Different formats belonging to the same family must have different names, but can use
  # the same name for ContextDefs related to the same destination data fields.
  # (That is: 2 different 'event' ContextDefs belonging to 2 different formats but belonging
  #  to the same family can share the same 'event' name, independently from the actual destination
  #  data fields collected therein.)
  #
  # rubocop:disable Metrics/ClassLength
  class FormatParser
    # FormatParser will throw an exception if the format validity check of a ContextDef takes more than this value of seconds.
    REGEXP_TIMEOUT_IN_SEC = 5.0

    # Source document and its copy split in pages & rows
    attr_reader :document, :pages, :page_index

    # GogglesDb::Season detected from the filename specified in the constructor.
    attr_reader :season

    # Current format name (String)
    attr_reader :format_name

    # Overall result & latest format def used for parsing; this may change between page breaks
    # and it will always be the last one reported as valid from the latests parse() call.
    attr_reader :result_format_type

    # Result top level ContextDAO container: all defined and used root-level contexts will become its rows
    # and related siblings will become rows of their respective parents to preserve hierarchy.
    # Typically a root DAO should contain a single ContextDAO sibling called 'header'.
    attr_reader :root_dao

    # ContextDefs Hash indexed by format name
    attr_reader :format_defs

    # Hash of Hash storing all successful check results for each ContextDef from the last parse run,
    # using <format_name> as key and having as value an Hash structure:
    #
    #   { <format_name> => { <context_def_name> => <valid_result> } }
    #
    # == Notes:
    # - Failing contexts won't be added to this list. Resets on every page or format change;
    # - the current format will be considered valid if all required contexts are within this list;
    # - formats can change on each new document page;
    # - a #parse scan will continue using the same successful format found until failure.
    attr_reader :valid_scan_results

    # Hash of Hash storing all check results for each defined format found and tried by a #scan().
    # A format is considered valid if all its required contexts have been satisfied.
    #
    # With structure:
    #
    #   <format_name> => {
    #     :valid => +true+ for valid formats
    #     :last_check => page index of last successful format application
    #     :valid_at => Array of page indexes (0..N) for which <format_name> has been found valid
    #   }
    #
    attr_reader :checked_formats

    #-- -----------------------------------------------------------------------
    #++

    # Creates a new FormatParser given a source pathname pointing to a valid text file
    # to be parsed and analyzed.
    #
    # FormatParser will split & scan multiple pages assuming EOP are using the ASCII Form-feed
    # character (DEC 12, HEX 0C => "\x0c").
    #
    # Multiple formats per single file are supported, as long as a *single* format is used
    # on each page.
    #
    # FormatParser will use the first format found valid to determine which "family" of formats
    # will be using for the rest of the file and will carry on using that same successful format
    # until the required format definitions (ContextDef) in the current format are no
    # longer satisfied on the current page.
    # Consequently, it will then loop on all remaining sub-formats belonging on the same family until a
    # new successful one is found while progressing with the page parsing.
    #
    # The parsing using #scan() may stop before the last page if no more valid formats are existing
    # in the applied format family.
    #
    # To force a specific format on a group of pages, use #parse() instead.
    #
    # == Params
    # - <tt>filename</tt> => a full pathname to the source text document to be scanned/parsed.
    #
    # - <tt>skip_logging</tt> => skip parsing operations logging; logging creates a file with the
    #   same basename as the source document with a '.log' extension. Default: false.
    #
    # - <tt>verbose_log</tt> => enables the debug logging of the main steps inside ContextDef#valid?()
    #                           for *each* context call. Mostly useful only when parsing or testing single
    #                           pages as the log file will quickly become huge in size for more than one.
    #                           Default: false.
    #
    # - <tt>:debug</tt> => override for the default +false+;
    #                      when +true+ the log messages will also be redirected to the system console
    #                      as an addition to the default log file created using the same basename as the source document.
    #
    # === Example usage:
    #
    # Full document scan with verbose logging on console:
    #
    # > fp = PdfResults::FormatParser.new('app/strategies/pdf_results/formats/results_2022-12-18_Brunelleschi.txt')
    # > fp.scan(debug: true) # default: false
    #
    # Partial document scan with verbose logging on console:
    #
    # > fp.scan(pages: 10..15, debug: true)
    #
    # Focused parsing, using just a specific format:
    #
    # > fp.parse('app/strategies/pdf_results/formats/1-ficr1.100m.yml', pages: 0..5, debug: true)
    #
    def initialize(filename, skip_logging: false, verbose_log: false, debug: false)
      @document = File.read(filename)
      @verbose_log = verbose_log
      detect_season_from_pathname(filename)
      prepare_logger(filename) unless skip_logging
      @debug = debug
      set_current_page_rows
    end
    #-- -----------------------------------------------------------------------
    #++

    # Detects & returns which known layout format the data file belongs to.
    # Sets the +result_format_type+ with the name/key of the first matching format found for the
    # first page specified in the constructor.
    #
    # Each #scan invocation clears both the #log and #daos.
    # Returns +nil+ when the file uses an unknown format (unknown considered all format
    # files found) or in case of errors.
    #
    # After the first page of the source document is scanned, the "winning" format
    # will also set the format family.
    # After each page break (if any), only formats belonging to the same format family
    # will be checked for validation whenever the original "winning" format stops
    # being valid for any reason.
    #
    # (This allows to have files with multiple formats in them, as long as they all
    # belong to the same family.)
    #
    # The scan ends either when the last document line is reached or there are
    # no more applicable (file) formats to be checked against the remaining pages.
    #
    # == Options
    # - <tt>:ffamily_filter</tt> => specify the format family basename for force a focused scanning
    #   just on that family of formats; leave blank to scan using all available formats.
    #   ("First valid found, first served.")
    #
    # - <tt>:limit_pages</tt> => a single integer or a range of values, identifying the processed
    #   pages (0..COUNT-1); default: +nil+ to parse the whole source file.
    #   Any starting value will make the document page index start from that point and continue
    #   until the end of the document or the ending page index value, if set.
    #
    # - <tt>:debug</tt> => override for the default +false+; when +true+ the log messages
    #   will also be redirected to the system console as an addition to the default log file
    #   created using the same basename as the source document.
    #
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def scan(ffamily_filter: '', limit_pages: nil, debug: @debug) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      @debug = debug
      @logger.reopen
      set_current_page_rows(limit_pages:)
      log_message('No pages to scan!') && return if @pages.blank? || @rows.blank?

      # Scan all defined/available format layouts found, page-by-page:
      fmt_files = Rails.root.glob("app/strategies/pdf_results/formats/#{ffamily_filter}*.yml")
      fmt_files_idx = 0
      # 1. Get first format file name
      format_filepath = fmt_files&.first
      current_fname = format_filepath.basename.to_s.gsub('.yml', '')
      ffamily_name = current_fname&.split('.')&.first
      @checked_formats = {} # hash for keeping track of repeated checks on same format types
      continue_scan = @checked_formats.keys.count { |key| key != 'EMPTY' } < fmt_files.count && format_filepath.present?

      while continue_scan
        log_message("\r\n✴✴✴ 🩺 Checking '#{current_fname}' (base: #{ffamily_name}, fmt: #{fmt_files_idx + 1}/tot: #{fmt_files.count}) @ page idx: #{@page_index}/tot: #{@pages.count} ✴✴✴")
        @checked_formats[current_fname] ||= {}
        @checked_formats[current_fname][:valid_at] ||= []

        # Parse will carry on with the current format until last page is reached
        # or the format isn't valid anymore on the current page:
        parse(format_filepath, limit_pages:)

        # 2. Store last format check position (regardless of results) & bail-out when actual EOF is reached with a valid format:
        @checked_formats[current_fname][:last_check] = @page_index
        # Break out if last page is reached and we still have a result format:
        break if @page_index >= @pages.count && @result_format_type.present?

        # (Loop concept)
        #  A. page_index.positive? (&& !valid?)
        #   => change format but carry on with same format family:
        #     => filter out extra formats from the list of basenames (can be done safely more than once)
        #  B. page_index.zero? (&& !valid?)
        #   => try with next file name in list (no filtering)

        # 3. Format filtering (limit the formats to be checked after a first successful scan on page zero)
        #    Filter out fmt_files keeping only files belonging to the same family for any format failure
        #    after page zero.
        #    (We should be able to re-test the list of same-family formats from the start if the format
        #     changes in between page breaks and we still have document to parse.)
        fmt_files.select! { |fn| fn.basename.to_s.include?(ffamily_name) } if @page_index.positive?

        # (Move to the next file or repeat the list check from start if we haven't wrapped the
        # format list already on the same page.)

        # Move to next file path or wrap to the beginning of the list:
        fmt_files_idx += 1
        if fmt_files_idx >= fmt_files.count
          fmt_files_idx = 0
          log_message("=> WRAPPING UP format index, after \033[33;1;3m'#{current_fname}'\033[0m failed @ page: #{@page_index + 1}/#{@pages.count})")
        end

        # Update file name, key format name & family name:
        format_filepath = fmt_files[fmt_files_idx]
        current_fname = format_filepath&.basename&.to_s&.gsub('.yml', '')
        ffamily_name = current_fname&.split('.')&.first
        # Already checked using same format at same page? => Bail out!
        break if @checked_formats.key?(current_fname) &&
                 @checked_formats[current_fname][:last_check] == @page_index

        log_message("--> Coming up next: '#{current_fname}'...") if current_fname
        continue_scan = fmt_files_idx < fmt_files.count && format_filepath.present?
      end

      log_message("\r\nFormat list scanning results:")
      @checked_formats.each do |fname, hsh_res|
        log_message(
          Kernel.format('- %s: %s, last checked at page idx %d, valid at pages: %s',
                        fname, hsh_res[:valid] ? "\033[1;33;32m✔\033[0m" : 'x', hsh_res[:last_check].to_i,
                        hsh_res[:valid_at]&.flatten&.uniq.to_s)
        )
      end
      log_message("\r\nApplied format family: '#{ffamily_name}', latest found: #{@result_format_type}")

      # Whole document scanned ok?
      if @page_index >= @pages.count && @result_format_type.present?
        puts "\r\n--> \033[1;33;32mWHOLE document parsed! ✔\033[0m"
      else
        puts "\r\n--> \033[1;33;31mParsing STOPPED at page idx #{@page_index + 1}/#{@pages.count}\033[0m"
      end

      @logger.close
      # Return last valid & used format type name:
      @result_format_type
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    #-- -----------------------------------------------------------------------
    #++

    # Given a YAML file path allegedly storing a valid list of ContextDef definitions
    # (all under a single key, the format type name), tries to parse the #document
    # given with the constructor.
    #
    # Each #parse invocation will append to the existing #log & #daos members unless
    # +reset_page_index+ is used.
    #
    # Parsing continues from the current page as signaled by the internal #page_index.
    # Parsing ends when the last document #row is reached or the specified +format_filepath+
    # seems to be not-applicable anymore.
    #
    # Parsing can be resumed using a different format on the current page, if there are
    # both a current page and another format available.
    #
    # Returns & sets @result_format_type value when successful or +nil+ if not.
    # Raises an exception if the YAML format-def file doesn't contain a valid list of ContextDef properties.
    #
    # Each run of #parse will clear and set new values for:
    #
    # - +result_format_type+ => key root string name found inside the specified +format_filepath+
    # - +valid_scan_results+ => Hash having as keys each ContextDef name together with its latests validation check result (true/false)
    # - +format_defs+  => Hash of ContextDefs, keyed by their name
    # - +format_order+ => Array ContextDef string names, setting the order in which the above defs have been found
    #
    # == Params:
    # - <tt>format_filepath</tt>  => format file pathname;
    #
    # == Options
    # - <tt>:limit_pages</tt> => a single integer or a range of values, identifying the processed
    #   pages (0..COUNT-1); default: +nil+ to parse the whole source file.
    #   Any starting value will make the document page index start from that point and continue
    #   until the end of the document or the ending page index value, if set.
    #
    # - <tt>reset_page_index</tt> => when +true+ the current #page_index will be reset
    #   to 0 together with all other member variables supporting the resulting format layout
    #   ("rewinds" the document).
    #
    # - <tt>:debug</tt> => override for the default +false+; when +true+ the log messages
    #   will also be redirected to the system console as an addition to the default log file
    #   created using the same basename as the source document.
    #
    def parse(format_filepath, limit_pages: nil, reset_page_index: false, debug: @debug) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      @debug = debug
      # 1. Build the hash list of ContextDef, defining & describing the current layout format:
      @format_name = prepare_format_defs_from_file(format_filepath)

      # 2. Set the current array of @rows for the current page:
      set_current_page_rows(limit_pages:, rewind: reset_page_index)

      # 3. Scan each ContextDef present in @format_defs, progressing in source text scan index
      #    as much as actual row span also progressing page-by-page:
      log_message("=> FORMAT '\033[1;93;40m#{@format_name}\033[0m' @ page: #{@page_index + 1}/#{@pages.count}")
      ctx_index = 0
      row_index = 0
      ctx_name  = @format_order.at(ctx_index)

      # === EMPTY PAGE ===
      if @rows.blank? # Skip empty pages and move forward:
        log_message("\r\nEMPTY page found @ page idx #{@page_index}")
        $stdout.write("\033[1;33;32m.\033[0m") # "Valid" progress signal
        @result_format_type = 'EMPTY' # special "empty page" format name
        @checked_formats['EMPTY'] = { valid: true, valid_at: [@page_index] } # Store just last empty page encountered
        @page_index += 1
        set_current_page_rows(rewind: false)
        return
      end

      continue_scan = row_index < @rows.count && ctx_name.present?

      while continue_scan
        # Set the current context:
        context_def = @format_defs.fetch(ctx_name, nil)
        break unless context_def.is_a?(ContextDef)

        # Validate current context by extraction:
        # DEBUG
        if @debug
          log_message(
            Kernel.format("\r\n➡ row %04d/%04d, p: %s/%s [\033[1;94;3m%s\033[0m: '\033[1;93;40m%s\033[0m', ctx %02d/%02d]",
                          row_index, @rows.count - 1, @page_index + 1, @pages.count, @format_name, ctx_name, ctx_index + 1, @format_order.count)
          )
        end
        # -----------------------------------------------------------------------
        # TODO: FIND a way to reference actual parent container valid? AND NOT last_check_result,
        #       which may or may not refer to the current parent while being run on the same buffer
        #       AND not the buffer lines which made the parent itself valid for as a container for the current ctx
        # ------------------------------------------------------------------
        # Parent, if set, must be valid too for a sibling to pass the check:
        # parent_valid = context_def.parent.blank? || (context_def.parent.present? && context_def.parent.last_validation_result)
        # -----------------------------------------------------------------------

        # DEBUG
        # Signal the start of the validity check before doing it, so that we can spot RegExps with possible catastrophic backtracking
        # (anthing more than a handful of seconds surely involves too many steps)
        # $stdout.write("\033[1;33;30m?\033[0m")
        valid = false
        timing = Benchmark.measure do
          # Can't *AND* the following check with parent_valid as this is NOT currently possible: valid? gets overridden each time
          valid = context_def.valid?(@rows, row_index)
        end

        # Prevent excessive RegExp backtracking (unit = seconds):
        raise "Excessive RegExp backtracking: timeout reached! Try to be more precise for the format of '#{context_def.name}'" if timing.real > REGEXP_TIMEOUT_IN_SEC

        # DEBUG
        if @debug && (context_def.key.present? || context_def.consumed_rows.positive?)
          log_message(Kernel.format("  [%s] => %s -- curr_index: %d, consumed_rows: %d\r\n  |=> key: '\033[1;33;32m%s\033[0m'",
                                    ctx_name, result_icon_for(context_def), context_def.curr_index, context_def.consumed_rows,
                                    context_def.key))
        end

        row_index = progress_row_index_and_store_result(row_index, valid, @format_name, context_def)
        # DEBUG
        if @debug && context_def.last_validation_result
          log_message(Kernel.format("  |=> next: %04d/%04d (from: '%s' ctx idx: %d, ctx span: %d)", row_index, @rows.count - 1,
                                    context_def.name, context_def.curr_index, context_def.row_span))
        end

        # == Exit / Bail out:
        # (NOT valid?) AND required and (NOT repeatable) and
        #   (prev Ctx NOT repeatable) and (at root?) => end of validity check (FAIL)
        # (Can't move forward and should NOT check on another buffer chunk)
        break if !valid && context_def.required? && !context_def.repeat? && !prev_context(ctx_index)&.repeat? &&
                 context_def.parent.blank?

        # == Recurse to parent when set:
        # (NOT valid?) and (parent context existing? && required) and (check not repeated)
        # => back/recurse to parent:
        # NOTE: the parent context may be set up with just its name if it hasn't been encountered yet, so we
        # make sure we're passing the actual parent name:
        parent_name = context_def.parent.respond_to?('name') ? context_def.parent.name : context_def.parent
        # Assume the parent was optional if it wasn't properly setup:
        parent_required = context_def.parent.respond_to?('required?') ? context_def.parent.required? : false
        if !valid && context_def.parent.present? && parent_required &&
           !check_already_made?(parent_name, row_index)
          # Set pointers for next iteration:
          ctx_name = parent_name
          ctx_index = @format_order.index(ctx_name)
          validate_context(ctx_index)
          # $stdout.write("\033[1;33;30mP\033[0m") # signal "PARENT"
          log_message(Kernel.format("  \\__ (back to PARENT '\033[94;3m%s\033[0m')", ctx_name))

        # == Recurse to previous context if it was repeatable:
        # (NOT valid) and (prev Ctx repeatable) and (check not repeated)
        #  => back/recurse to previous:
        elsif !valid && ctx_index.positive? && prev_context(ctx_index)&.repeat? &&
              !check_already_made?(@format_order.at(ctx_index - 1), row_index)
          # Set pointers for next iteration:
          ctx_index -= 1
          ctx_name  = @format_order.at(ctx_index)
          validate_context(ctx_name)
          # DEBUG
          # $stdout.write("\033[1;33;30m⬅\033[0m") # signal "BACK to prev."
          log_message(Kernel.format("  \\__ (back to prev. '\033[94;3m%s\033[0m')", ctx_name))

        # == Next context: in any other case, always move forward to next context
        else
          ctx_index += 1
          if ctx_index < @format_order.count
            ctx_name = @format_order.at(ctx_index)
            validate_context(ctx_name)
            # DEBUG
            # $stdout.write("\033[1;33;30m_\033[0m") # signal "NEXT"
            log_message(Kernel.format("  \\__ checking next, '\033[94;3m%s\033[0m'", ctx_name))
          else
            log_message("      <<-- \033[1;33;31mEND OF FORMAT LOOP '\033[1;93;40;3m#{@format_name}\033[0m' -->>")
            # $stdout.write("\033[1;33;30m^\033[0m") # signal "Ctx Loop wrap"
          end
        end

        # DEBUG VERBOSE
        if @debug
          log_message(Kernel.format("      At loop wrap: idx => %04d (from: '\033[94;3m%s\033[0m' idx: %d, span: %d)",
                                    row_index, context_def.name, context_def.curr_index, context_def.row_span))
          log_message("      \033[38;5;3m-----------------------------------------------------------------------\033[0m")
        end

        # === STORE DATA ===
        # ASAP the context scan is completed, even before page end, create/update
        # the root DAO, so we don't miss "fragmented data pages" that may require
        # the "Repeatable loop restart" to be parsed out completely:
        if valid && all_required_contexts_valid?(@format_name)
          # Store data - append page daos to the root DAO:
          @root_dao ||= ContextDAO.new
          # DEBUG
          # $stdout.write("\033[1;33;30mm\033[0m") # Signal "Merge DAOs"
          @page_daos.each { |dao| @root_dao.merge(dao) }
        end

        # === PAGE END/BREAK ===
        # Handle page ends or page breaks (EOPs) or row limit when reached,
        # only after ALL ctxs have been checked out.
        # (Page change occurs only if there are NO more rows or if a EOP-context has been found valid,
        #  in any other case, the current format should be considered as not checked out completely or invalid;
        #  ctx could be repeatable in check until the actual end of rows and a required and repeatable ctx
        #  could be found later on.)
        if valid && all_required_contexts_valid?(@format_name) && (row_index >= @rows.count || context_def.eop?)
          $stdout.write("\033[1;33;32m.\033[0m") # "Valid" progress signal (once per page)
          log_message(
            Kernel.format("\r\nFORMAT '\033[1;93;40;3m%s\033[0m' VALID! ✅ @ page %d/%d",
                          @format_name, @page_index + 1, @pages&.count.to_i)
          )
          # Set the result at the end of all context def scan and only at the end of the page:
          @result_format_type = @format_name

          @checked_formats ||= {}
          @checked_formats[@format_name] ||= {}
          @checked_formats[@format_name][:valid] = true
          @checked_formats[@format_name][:valid_at] ||= []
          @checked_formats[@format_name][:valid_at] << @page_index unless @checked_formats[@format_name][:valid_at].include?(@page_index)

          # Page progress & reset indexes:
          @page_index += 1
          set_current_page_rows(rewind: false)
          row_index = 0
          ctx_index = 0
          ctx_name  = @format_order.first
          msg = if @rows.count.positive?
                  Kernel.format("\r\n  EOP found (%s): new page %d/%d", context_def.name, @page_index, @pages&.count.to_i)
                else
                  Kernel.format("\r\n  EOF found (%s): no more rows.", context_def.name)
                end
          log_message(msg)
          log_message("\r\n[#{@format_name}] Scan result for detecting formats (resets each page change):")
          @valid_scan_results[@format_name].each { |name, is_valid| log_message("- #{name}: #{is_valid ? "\033[1;33;32m✔\033[0m" : 'x'}") }

          # Always reset page result counters & page DAOs before the next iteration
          # (even when using same format - any DAOs found valid are "storable" only if the
          # whole page satisfies the layout definition and the DAOs should have been already
          # merged before the following lines):
          @valid_scan_results = { @format_name => {} } # (This should reset on every page change)
          @page_daos = []
        end

        # === "REPEATABLES" RESTART ===
        # Valid or not, if there are still rows to process and we have "Repeatables" to check,
        # restart the loop from the first "repeatable" context stored:
        if (row_index < @rows.count) && (ctx_index >= @format_order.count) && @repeatable_defs.keys.present? &&
           !check_already_made?(@repeatable_defs.keys.first, row_index)
          # Set pointers for next iteration - RESTART "repeatables":
          ctx_name = @repeatable_defs.keys.first
          ctx_index = @format_order.index(ctx_name)
          validate_context(ctx_index)
          # DEBUG
          # $stdout.write("\033[1;33;30m♻\033[0m") # Restart loop signal
          log_message(Kernel.format("  \\__ (RESTARTING repeatables from first: '\033[94;3m%s\033[0m')", ctx_name))
        end

        # Make sure the result format is cleared out at the end of each loop, unless found ok:
        @result_format_type = nil unless valid

        # Continue scanning page with this format whenever we have more rows to process
        # AND still other context defs to check out at the current row pointer:
        continue_scan = (row_index < @rows.count) && (ctx_index < @format_order.count)
      end

      unless valid
        $stdout.write("\033[1;33;31m✖\033[0m") # "INVALID format" progress signal (EOP reached, or not, w/o some of the constraints satisfied)
        # Output where last format stopped being valid:
        puts("'#{@format_name}' [#{ctx_name}] => stops @ page idx #{@page_index}") if @rows.present?
      end

      log_message("\r\nLast check for repeatable defs (w/ stopping index):")
      @repeatable_defs.each do |name, hsh|
        log_message(
          Kernel.format('- %<name>s: last checked @ row: %<last_check>d => %<check_result>s, valid rows (in valid pages): %<valid_list>s',
                        name:, last_check: hsh[:last_check].to_i,
                        check_result: hsh[:valid] ? "\033[1;33;32m✔\033[0m" : 'x',
                        valid_list: hsh.fetch(:valid_at, []).flatten.uniq.to_s)
        )
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # Prepares both the @logger & the @logfile instances given the source document +filename+.
    def prepare_logger(filename)
      basename = File.basename(filename).split('.').first
      dirname = File.dirname(filename)
      @logfile = File.open(File.join(dirname, basename + '.log'), 'w+')
      @logger = Logger.new(@logfile,
                           datetime_format: '%Y%m%d %H:%M:%S',
                           formatter: proc { |_severity, _datetime, _progname, msg| "#{msg}\r\n" })
    end

    # Returns a valid Season assuming current +filename+ contains the season ID as
    # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
    # Defaults to season ID 222 if no valid integer was found in the last folder of the path.
    # Sets @season with the specific Season retrieved.
    def detect_season_from_pathname(filename)
      season_id = File.dirname(filename).split('/').last.to_i
      season_id = 222 unless season_id.positive?
      @season = GogglesDb::Season.find(season_id)
    end

    # Resets (or selects) the document pages range and its consequent current page rows
    # that have be processed, while setting the internal index (@page_index), the @rows
    # buffer itself.
    #
    # To be called when starting any scan or parse process and on any page change.
    #
    # == Options
    # - <tt>:limit_pages</tt> => a single integer or a range of values, identifying the processed
    #   pages (0..COUNT-1); default: +nil+ to parse the whole source file.
    #   Any starting value will make the document page index start from that point and continue
    #   until the end of the document or the ending page index value, if set.
    #
    # - <tt>:rewind</tt> => +true+ to reset current page index to 0 (default).
    #   Note that if <tt>:limit_pages</tt> the page index will be rewind already at the
    #   starting value of the specified range (or integer).
    #   Using +false+ will preserve the current index value.
    #
    def set_current_page_rows(limit_pages: nil, rewind: true) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      # Reset the page index only when requested:
      if rewind || @page_index.blank?
        log_message("\r\n*** Document RESET & REWIND ***")
        @page_index = 0
      end

      # Limit the number of pages and extract the rows buffer from the current page:
      @pages = if limit_pages.is_a?(Integer)
                 [@document.split("\x0c")[limit_pages]]
               elsif limit_pages.is_a?(Range)
                 @document.split("\x0c")[limit_pages]
               elsif @pages.blank?
                 @document.split("\x0c")
               else # Don't touch already filtered pages:
                 @pages
               end
      # Get & split current page into an Array of rows:
      @rows = if @pages.is_a?(Array)
                @pages&.fetch(@page_index, nil)&.split(/\r?\n/) || []
              else
                []
              end
    end

    # Resets the result members and prepares the @format_defs Hash for scanning
    # the source document page or pages.
    #
    # === Clears and prepares:
    # - result_format_type
    # - format_defs
    # - repeatable_defs
    # - format_order
    # - @page_daos (because each page is assumed to have only 1 format)
    #
    # This allows #parse() to work with single formats page-by-page until detection
    # for the same format fails, while also collecting DAOs even when resuming scan
    # with a different format file.
    #
    #
    # == Returns:
    # The string format name usable as key for this format type.
    #
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/AbcSize, Metrics/PerceivedComplexity
    def prepare_format_defs_from_file(format_filepath)
      layout_def = YAML.load_file(format_filepath)
      format_name = layout_def.keys.first
      context_props_array = layout_def[format_name]

      # Init result variables:
      @result_format_type = nil # chosen & valid format type (FIFO)

      # Actual scan result (keyed by format name & sub-keyed by ContextDef type-name);
      @valid_scan_results = { format_name => {} } # (This should reset on every page change)

      @format_defs = {}         # Hash list of ContextDef
      @repeatable_defs = {}     # Hash for keeping track of repeatable checks (keyed by context name)
      @format_order = []        # requested format order
      @page_daos = []           # Collection of DAOs found on current page
      # NOTE: page DAOs are cleared on each page break and stored
      #       into @root_dao only if the current overall format is successful

      context_props_array.each do |context_props|
        # Set proper parent reference:
        # (ASSUMES: parent context must be already defined)
        if context_props['parent'].present? && context_props['parent'].is_a?(String)
          parent_ctx = @format_defs.fetch(context_props['parent'], nil)
          context_props['parent'] = parent_ctx if parent_ctx
        end
        context_def = ContextDef.new(context_props.merge(
                                       logger: @verbose_log ? @logger : nil, # Skip detailed logging unless verbose
                                       debug: @debug
                                     ))
        @format_defs[context_def.name] = context_def
        @repeatable_defs[context_def.name] = {} if context_def.repeat?
        @format_order << context_def.name
      end

      format_name
    end
    #-- -----------------------------------------------------------------------
    #++

    # Adds +msg+ to the internal log.
    # == Params
    # - msg: String message to be added to the log
    def log_message(msg)
      @logger&.debug(msg)
      Rails.logger.debug(msg) if @debug
    end

    # Returns a string representation of the type of result stored by the specified
    # FieldDef or a ContextDef. Usable for logging.
    def result_icon_for(obj)
      return "\033[1;33;31m⚠\033[0m" unless obj.is_a?(FieldDef) || obj.is_a?(ContextDef)
      return "\033[1;33;33m~\033[0m" if !obj.required? && !((obj.is_a?(ContextDef) && obj.last_validation_result) || obj.key.present?)
      return "\033[1;33;32m✔\033[0m" if obj.key.present? || (obj.is_a?(ContextDef) && obj.last_validation_result)

      "\033[1;33;31m✖\033[0m"
    end

    # Raises a runtime error in case the specified context index or name isn't valid.
    # (Assumes index to be a number and name to be a string)
    def validate_context(ctx_index_or_name)
      # Prevent nil contexts & signal format def error:
      existing = (ctx_index_or_name.is_a?(String) && @format_defs.key?(ctx_index_or_name)) ||
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
      @format_defs.fetch(@format_order.at(ctx_index - 1), nil)
    end

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

      # Find parent context if any:
      # (Retrieve parent ctx in lookup table or use the link if it's not a name -- may be nil, don't care)
      parent_ctx = context_def.parent.is_a?(String) ? @format_defs.fetch(context_def.parent, nil) : context_def.parent

      # Store data: add DAO to parent rows if parent && there was something
      # stored in the DAO:
      if parent_ctx&.dao.present? && context_def.dao.present?
        parent_ctx.dao.add_row(context_def.dao)
      elsif context_def.dao.present?
        @page_daos << context_def.dao
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

    # Returns true if the specified context_def name has already been verified with a
    # run at this same row_index. False otherwise.
    # === Note:
    # The idea is to avoid infinite loops without using recursion: we need to streamline the loops
    # and avoid checking rows or extracting from rows more than once if already done, independently
    # from the actual result.
    def check_already_made?(context_name, row_index)
      return false unless @repeatable_defs.key?(context_name)

      @repeatable_defs[context_name].fetch(:last_check, nil) == row_index
    end

    # Returns +true+ if all *required* contexts defined in @format_defs have been satisfied.
    # Relies on @valid_scan_results to store the result of the scan for a specific context name.
    def all_required_contexts_valid?(format_name)
      @format_defs.all? do |ctx_name, ctx|
        ctx.required? ? @valid_scan_results.key?(format_name) && @valid_scan_results[format_name].key?(ctx_name) && @valid_scan_results[format_name][ctx_name] : true
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
# rubocop:enable Metrics/ClassLength
