# frozen_string_literal: true

module PdfResults
  # = PdfResults::L2Converter
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #
  # Converts from any parsed field hash to the "Layout type 2" format
  # used by the MacroSolver.
  #
  # rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  class L2Converter
    # RegExp used to detect a possible timing value, with optional minutes
    POSSIBLE_TIMING_REGEXP = /\d{0,2}['\"\s:.]?\d{2}[\"\s:.,]\d{2}/i

    # Supported "parent" section names for *individual results*. Laps & delta timings are
    # automatically detected and collected as long as their name has the format
    # "lap<length>" and "delta<length>".
    #
    # A parent result section can have any of these supported names, but ONLY ONE of them
    # shall be the one required while all the others coexisting with it must be set as
    # "alternative_of: <original_name>" and "required: false" in order for the layout
    # to be logically correct and supported by the #data() gathering method of the DAO objects.
    #
    # Any result or lap can be split freely into multiple subsection or sub-rows and
    # each subsection/subrow name won't matter as all fields will be collected and become part
    # of a single parent hash.
    IND_RESULT_SECTION = %w[results results_alt].freeze

    # Supported 'swimmer_name' column fields for individual results ("_alt" names are automatically used for these).
    SWIMMER_FIELD_NAMES = %w[swimmer_name swimmer_ext swimmer_suffix swimmer_suffix].freeze

    # Supported 'team_name' column fields for individual results ("_alt" names are automatically used for these).
    TEAM_FIELD_NAMES = %w[team_name team_ext team_suffix team_suffix].freeze

    # Supported section names for *categories*. Same rules for IND_RESULT_SECTION apply.
    # Different names are supported in case they need to co-exist in the same layout file.
    CATEGORY_SECTION = %w[event category rel_category].freeze

    # Supported "parent" section names for *relay results*. Same rules for IND_RESULT_SECTION apply.
    REL_RESULT_SECTION = %w[rel_team rel_team_alt].freeze

    # Supported section names for *relay swimmers*. Same rules for IND_RESULT_SECTION apply.
    REL_SWIMMER_SECTION = %w[rel_swimmer rel_swimmer_alt].freeze

    # Supported source "Category type" field name.
    # (Internal format of the value stored therein may vary from layout to layout.)
    CAT_FIELD_NAME = 'cat_title'

    # Supported source "Gender type" field name.
    # (Internal format of the value stored therein may vary from layout to layout.)
    GENDER_FIELD_NAME = 'gender_type'
    #-- -------------------------------------------------------------------------
    #++

    attr_reader :data, :header, :session_month

    # Creates a new converter instance given the specified data Hash.
    #
    # == Params
    # - <tt>data_hash</tt> => data Hash resulting from a root level ContextDAO#data() call.
    # - <tt>season</tt> => GogglesDb::Season instance to which the data must be imported into.
    #
    # === Example:
    #
    # Assuming all data has been gathered and merged under a single header root node,
    # extract the data as an hash and use just the first element of the root node
    # (which should have the 'header' name key).
    #
    #   > data = root_dao.collect_data
    #   > data_hash = data[:rows].first
    #   =>
    #   {:name=>"header", ...
    #
    #   > PdfResults::L2Converter.new(data_hash, season).to_hash
    #
    # == Example *source* DAO data Hash structure (from the '1-ficr1' family):
    #
    #     +-- root
    #         [:rows]
    #           +-- header🔸
    #               [:rows]
    #                 +-- event🔸(xN, ind.)
    #                     [:rows]
    #                       +-- category (xN)
    #                           [:rows]
    #                             +-- results🔸(xN)
    #                             +-- (disqualified)
    #                       +-- publish_time
    #                       +-- footer🔸
    #                 +-- sub_title
    #                 +-- event🔸(xN, relays)
    #                       +-- rel_team🔸(xN)
    #                     [:rows]
    #                       +-- rel_team🔸(xN)
    #                           [:rows]
    #                             +-- rel_swimmer🔸(x4|x6|x8)
    #                       +-- (disqualified)
    #                       +-- publish_time
    #                       +-- footer🔸
    #                  +-- ranking_hdr
    #                      [:rows]
    #                        +-- team_ranking🔸(xN)
    #
    def initialize(data_hash, season)
      raise 'Invalid data_hash specified!' unless data_hash.is_a?(Hash) && data_hash[:name] == 'header'

      @data = data_hash
      @season = season
      # Collect the list of associated CategoryTypes to avoid hitting the DB for category code checking:
      @categories_cache = PdfResults::CategoriesCache.new(season)
      # Precompute header & session_month values:
      header
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns +true+ if the specified event title string represents a relay event; +false+ otherwise.
    def self.event_title_is_a_relay?(event_title)
      /(4|6|8)x\d{2,3}/i.match?(event_title.to_s)
    end

    # Returns the Hash header in "L2" structure (memoized).
    # Seeks values both the 'header' and 'event' context data rows.
    # Sets also the internal @header & @session_month instance variables.
    def header
      return @header if @header.present?

      # Check also header/session fields stored (repeatedly) in each event:
      first_event_hash = @data.fetch(:rows, [{}]).find { |row_hash| row_hash[:name] == 'event' }
      first_event_fields = first_event_hash&.fetch(:fields, {})
      # Try to retrieve some of the header fields also from the footer, if there are any:
      # (For the following to work, 'footer' must be a child of 'header', not 'event')
      footer_hash = @data.fetch(:rows, [{}]).find { |row_hash| row_hash[:name] == 'footer' }
      footer_fields = footer_hash&.fetch(:fields, {})

      # Extract meeting session date text from 2 possible places (header or event), then get the single fields:
      meeting_date_text = fetch_session_date(extract_header_fields) ||
                          fetch_session_date(first_event_fields) || fetch_session_date(footer_fields)
      session_day, @session_month, session_year = Parser::SessionDate.from_eu_text(meeting_date_text) if meeting_date_text.present?

      @header = {
        'layoutType' => 2,
        'name' => fetch_meeting_name, # (Usually, this is always in the header)
        'meetingURL' => '',
        'manifestURL' => '',
        'dateDay1' => session_day,
        'dateMonth1' => session_month,
        'dateYear1' => session_year,
        'venue1' => footer_fields&.fetch('meeting_venue_or_date', nil),
        'address1' => fetch_session_place(extract_header_fields) || fetch_session_place(first_event_fields) || fetch_session_place(footer_fields),
        'poolLength' => fetch_pool_type(extract_header_fields).last || fetch_pool_type(first_event_fields).last
      }
    end

    # Returns the Array of Hash for the 'event' sections in standard "L2" structure.
    # Handles both individual & relays events (distinction comes also from category later
    # down on the hierarchy).
    def event_sections # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      # Init the Array of resulting PdfResults::L2EventSection items (each one to be then converted into the final Hash form) or ready-to-go Hash ('rankings' or 'stats' sections):
      resulting_sections = []
      recompute_ranking = false
      data_hash_rows = @data.fetch(:rows, [{}])

      # === Event loop: ===
      puts("\r\n-> Event loop rows: #{data_hash_rows.count}")
      data_hash_rows.each_with_index do |event_hash, _idx| # rubocop:disable Metrics/BlockLength
        # Supported hierarchy for "event-type" depth level:
        #
        # [header]
        #     |
        #     +---[ranking_hdr|stats_hdr|event]
        #
        case event_hash[:name]
        when 'ranking_hdr'
          putc('R')
          # Supported hierarchy for "ranking_hdr" depth level:
          #   [ranking_hdr]
          #         +---[team_ranking]
          # Create a new section & add inconditionally (these usually are separated from the results):
          ranking_section = create_ranking_section(event_hash)
          resulting_sections << ranking_section if ranking_section.present?
        when 'fina_scores_hdr'
          putc('F')
          # Pass over the resulting sections in order to find/add & merge the scores to the correct section:
          create_fina_scores_sections(resulting_sections, event_hash)
        when 'stats_hdr'
          putc('S')
          # Create a new stats section & add it inconditionally:
          stats_section = create_stats_section(event_hash)
          resulting_sections << stats_section if stats_section.present?
        end
        # Ignore other unsupported contexts at this depth level:
        next unless event_hash[:name] == 'event'

        # TODO:
        # If the event_hash has either one of 'meeting_date' and/or 'meeting_place', store
        # them into the header to simplify Meeting match later on.

        # --- Extract all possible parent section fields from 'event' hash and use them in the loops below: ---

        # Reset parent event section reference when looping inside a new event context:
        section = nil
        curr_cat_code = nil

        # Sometimes the gender type may be found inside the EVENT title
        # (as in "4X50m Stile Libero Master Maschi" or "50 m Dorso Femmine"):
        event_title, event_length, _event_type_name, curr_cat_gender = fetch_event_title(event_hash)

        # --- RELAYS (event) ---
        if L2Converter.event_title_is_a_relay?(event_length) && holds_relay_category_or_relay_result?(event_hash)
          $stdout.write("\033[1;33;42mr\033[0m")
          curr_cat_code = fetch_rel_category_code(event_hash)
          curr_cat_gender ||= fetch_rel_category_gender(event_hash)

        # --- IND.RESULTS (event) ---
        elsif holds_category_type?(event_hash)
          $stdout.write("\033[1;33;42mi\033[0m")
          curr_cat_code = fetch_category_code(event_hash)
          curr_cat_gender ||= fetch_category_gender(event_hash)
        end
        # DEBUG ----------------------------------------------------------------
        # binding.pry
        # ----------------------------------------------------------------------

        # === Sub-event loop: ===
        # - sometimes the event section has all the fields
        # - sometimes header fields like category or gender need to be extracted result-by-result
        # => the section hash becomes defined only later on
        event_hash.fetch(:rows, [{}]).each do |row_hash|
          # Supported hierarchy for "sub-event-type" depth level:
          #
          # [event]
          #     |
          #     +---[category|rel_category] or [results|rel_team]
          #             |
          #             +---[results|rel_team]

          # --- RELAYS (sub-event, both with or w/o categ.) ---
          if L2Converter.event_title_is_a_relay?(event_length) && holds_relay_category_or_relay_result?(row_hash)
            # Get best parent section keys (at 3 possible depths, supporting latest values):
            curr_cat_code, curr_cat_gender = fetch_best_category_and_gender_codes_from_any_depth(event: event_hash, category: row_hash,
                                                                                                 def_category: curr_cat_code, def_gender: curr_cat_gender,
                                                                                                 relay: true)
            section = create_l2_event_section(event_title:, category_code: curr_cat_code, gender_code: curr_cat_gender,
                                              parent_data_hash: row_hash, relay: true)
            # == Hard-wired "manual forward link" for relay categories: ==
            # (Support different structure, either with or without a 'category'-type of parent)
            # DEBUG ----------------------------------------------------------------
            # binding.pry
            # ----------------------------------------------------------------------

            # NOTE:
            # As opposed to how indiv. results are processed (overriding section default with #fetch_best_category_and_gender_codes_from_any_depth),
            # here the relays are using the 'section' instance to pass around the keys to be used in each iteration.

            # Store current relay category & gender so that "unlinked" team relay
            # sections encountered later on, get to be bound to the latest relay fields found:
            # (this assumes the category section will be enlisted at least BEFORE actual the relay team result rows)
            if CATEGORY_SECTION.include?(row_hash[:name])
              # Don't overwrite current category code & gender pointers unless found in parent section:
              curr_cat_code = section.category_code if section.present? && section.category_code.present?
              curr_cat_gender = section.gender_code if section.present? && section.gender_code.present?
              $stdout.write("\033[1;33;32mr\033[0m") # green # rubocop:disable Rails/Output

              # Supported hierarchy (category -> rel_team):
              #
              # [category|rel_category]  (even incomplete/absolute rankings, w/ category post-computed or found in each result row)
              #     |
              #     +-- rel_team 🌀
              #         [:rows]
              #            +-- rel_swimmer 🌀
              #            +-- disqualified
              #
              # Loop on all category [:rows] (even if there's only 1 empty category including all results in "absolute rankings"),
              # and select all rel_team rows, building/adding or merging up the current sub-section with them:
              row_hash[:rows].select { |row| REL_RESULT_SECTION.include?(row[:name]) }.each do |rel_team_row|
                updated_section, recompute_row_result = translate_relay_data_hash(resulting_sections, section, rel_team_row)
                # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
                curr_cat_code = updated_section.category_code.presence || section.category_code.presence
                curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence
                # Even if just one row had the section "computed", we need to recompute the whole ranking:
                recompute_ranking = true if recompute_row_result
              end

            # Process directly teams & relay swimmers/laps:
            elsif REL_RESULT_SECTION.include?(row_hash[:name])
              updated_section, recompute_row_result = translate_relay_data_hash(resulting_sections, section, row_hash)
              # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
              curr_cat_code = updated_section.category_code.presence || section.category_code.presence
              curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence
              recompute_ranking = true if recompute_row_result
            end
          # -----------------------------------------------------------------

          # --- IND.RESULTS (event -> results: parents holds possibly some category data) ---
          elsif holds_category_type?(event_hash) && IND_RESULT_SECTION.include?(row_hash[:name])
            # Supported hierarchy:
            #
            # [event] (with partial gender or category data)
            #     |
            #     +---[results]
            #
            # Get best parent section keys (at 3 possible depths, supporting latest values):
            curr_cat_code, curr_cat_gender = fetch_best_category_and_gender_codes_from_any_depth(event: event_hash, category: row_hash,
                                                                                                 def_category: curr_cat_code,
                                                                                                 def_gender: curr_cat_gender)
            # DEBUG ----------------------------------------------------------------
            # binding.pry
            # ----------------------------------------------------------------------
            section = find_existing_event_section(resulting_sections, event_title, curr_cat_code, curr_cat_gender) ||
                      create_l2_event_section(event_title:, category_code: curr_cat_code,
                                              gender_code: curr_cat_gender, parent_data_hash: event_hash)

            updated_section, recompute_row_result = translate_ind_result_data_hash(resulting_sections, section, row_hash)
            # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
            curr_cat_code = updated_section.category_code.presence || section.category_code.presence
            curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence
            recompute_ranking = true if recompute_row_result

          # --- IND.RESULTS (category -> results: curr depth holds category data) ---
          elsif holds_category_type?(row_hash)
            # Supported hierarchy (extract both):
            #
            # [category] (even nil => absolute listing)
            #     |
            #     +---[results] (support sub-rows, if any)
            #
            sub_rows = row_hash.fetch(:rows, [{}])

            if sub_rows.count.positive? # process each sub-row at current depth + 1 into same section:
              sub_rows.each do |result_data_hash|
                # Get best parent section keys (at 3 possible depths, supporting latest values):
                curr_cat_code, curr_cat_gender = fetch_best_category_and_gender_codes_from_any_depth(event: event_hash, category: row_hash, result: result_data_hash,
                                                                                                     def_category: curr_cat_code,
                                                                                                     def_gender: curr_cat_gender)
                # DEBUG ----------------------------------------------------------------
                # binding.pry
                # ----------------------------------------------------------------------
                section = find_existing_event_section(resulting_sections, event_title, curr_cat_code, curr_cat_gender) ||
                          create_l2_event_section(event_title:, category_code: curr_cat_code,
                                                  gender_code: curr_cat_gender, parent_data_hash: row_hash)

                # DEBUG ----------------------------------------------------------------
                # binding.pry
                # ----------------------------------------------------------------------
                updated_section, recompute_row_result = translate_ind_result_data_hash(resulting_sections, section, result_data_hash)
                # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
                curr_cat_code = updated_section.category_code.presence || section.category_code.presence
                curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence
                recompute_ranking = true if recompute_row_result
              end
            else # store current-depth data in current section:
              # Get best parent section keys (at 3 possible depths, supporting latest values):
              curr_cat_code, curr_cat_gender = fetch_best_category_and_gender_codes_from_any_depth(event: event_hash, category: row_hash,
                                                                                                   def_category: curr_cat_code,
                                                                                                   def_gender: curr_cat_gender)
              # DEBUG ----------------------------------------------------------------
              # binding.pry
              # ----------------------------------------------------------------------
              section = find_existing_event_section(resulting_sections, event_title, curr_cat_code, curr_cat_gender) ||
                        create_l2_event_section(event_title:, category_code: curr_cat_code,
                                                gender_code: curr_cat_gender, parent_data_hash: row_hash)

              updated_section, recompute_row_result = translate_ind_result_data_hash(resulting_sections, section, row_hash)
              # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
              curr_cat_code = updated_section.category_code.presence || section.category_code.presence
              curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence
              recompute_ranking = true if recompute_row_result
            end

          # --- IND.RESULTS (event -> results, but NO category fields at all; i.e.: "absolute rankings") ---
          elsif IND_RESULT_SECTION.include?(row_hash[:name])
            # Need to reconstruct both category & rankings (no category data):
            recompute_ranking = true
            # Don't use defaults unless we have full category data:
            section = create_l2_event_section(event_title:, category_code: nil, gender_code: nil, parent_data_hash: event_hash)

            # DEBUG ----------------------------------------------------------------
            # binding.pry
            # ----------------------------------------------------------------------
            updated_section, _recompute_row_result = translate_ind_result_data_hash(resulting_sections, section, row_hash)
            # Update current cat.code & gender pointers whenever the section gets overwritten (or keep section defaults):
            curr_cat_code = updated_section.category_code.presence || section.category_code.presence
            curr_cat_gender = updated_section.gender_code.presence || section.gender_code.presence

          # --- (Ignore unsupported contexts) ---
          else
            next
          end
        end
      end

      result = recompute_ranking ? recompute_ranking_for_each_event_section(resulting_sections) : resulting_sections
      result.map { |section| section.is_a?(PdfResults::L2EventSection) ? section.to_l2_hash : section }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds up the event & category section that will hold the result rows (for *any* kind of results).
    # Safe to call even if the parent_data_hash isn't of the "category" type: it will
    # build just the event title instead.
    #
    # Note that 'event_title', 'category_code' & 'gender_code' are used for default section values
    # whereas 'parent_data_hash' can't provide them.
    #
    # == Params:
    # - <tt>event_title</tt>: the string title for the event being processed;
    #   value of field "title" in the section being searched or added.
    #
    # - <tt>category_code</tt>: the string category code for the event being processed;
    #   value of field "fin_sigla_categoria" in the section being searched or added.
    #
    # - <tt>gender_code</tt>: the string gender code (1 char) for the event being processed;
    #   value of field "fin_sesso" in the section being searched or added.
    #
    # - <tt>parent_data_hash</tt>: result row Hash in L2 format, ready to be added to the "rows" array of the section being searched or added.
    #
    # - <tt>relay</tt>: +true+ for relay sections; default: +false+
    #
    # == Returns:
    # A new PdfResults::L2EventSection reference storing the keys & any additional fields values.
    #
    def create_l2_event_section(event_title:, category_code:, gender_code:, parent_data_hash: {}, relay: false)
      # Prepare additional fields for the section:
      additional_timing_keys = %w[base_time ita_record ita_record_notes eu_record eu_record_notes]
      additional_misc_keys = []
      additional_fields = {}
      parent_data_hash.fetch(:fields, {}).each do |key, value|
        additional_fields[key] = format_timing_value(value) if additional_timing_keys.include?(key)
        additional_fields[key] = value if additional_misc_keys.include?(key)
      end

      curr_cat_code = relay ? fetch_rel_category_code(parent_data_hash) : fetch_category_code(parent_data_hash)
      curr_cat_gender = relay ? fetch_rel_category_gender(parent_data_hash) : fetch_category_gender(parent_data_hash)

      # The EventSection class will normalize internally all fields:
      PdfResults::L2EventSection.new(
        event_title:,
        category_code: curr_cat_code || category_code,
        gender_code: curr_cat_gender || gender_code,
        categories_cache: @categories_cache, additional_fields:
      )
    end

    # Builds up the "event" section that will hold the overall team ranking rows (when present).
    def create_ranking_section(event_hash)
      return unless event_hash.is_a?(Hash)

      section = {
        'title' => 'Overall Team Ranking',
        'ranking' => true, # Commodity flag used by the MacroSolver
        'rows' => []
      }
      event_hash.fetch(:rows, [{}]).each do |ranking_hash|
        # Ignore unsupported contexts at this depth level:
        next unless ranking_hash[:name] == 'team_ranking'

        section['rows'] << {
          'pos' => ranking_hash.fetch(:fields, {})['rank'],
          'team' => ranking_hash.fetch(:fields, {})['team_name'],

          # TODO: missing from table 'meeting_team_scores', so we can't handle these 2:
          # 'swimmer_events' => ranking_hash.fetch(:fields, {})['swimmer_events'],
          # 'registered_swimmers' => ranking_hash.fetch(:fields, {})['registered_swimmers'],

          'ind_score' => ranking_hash.fetch(:fields, {})['ind_score'],
          # |=> 'meeting_team_scores.meeting_points' & 'meeting_team_scores.sum_individual_points'
          'overall_score' => ranking_hash.fetch(:fields, {})['overall_score']
          # |=> 'meeting_team_scores.meeting_team_points' & 'meeting_team_scores.sum_team_points'
        }
      end

      section
    end

    # Builds up *ALL* the "event" sections scanning the FINA Scores summary,
    # which stores all individual & team result rows with their valid scores.
    #
    # This 'condensed format' will store a single event result x each row, including
    # the result timing and its overall score, so this method will need to build any
    # missing events or add the result row to any event found already converted.
    def create_fina_scores_sections(resulting_sections, event_hash)
      return unless event_hash.is_a?(Hash)

      puts("\r\n-> FINA scores contiguous rows: #{event_hash.fetch(:rows, [{}]).count} (i: individ., r: relay results)")
      event_hash.fetch(:rows, [{}]).each do |scores_hash|
        fields = scores_hash.fetch(:fields, {})
        rank = fields.fetch('rank', '')
        category_code = fields.fetch('cat_code', '')
        event_length  = fields.fetch('event_length', '')
        event_style   = fields.fetch('event_style', '')
        team_name = fields.fetch('team_name', '')
        timing = format_timing_value(fields.fetch('timing', ''))
        score  = fetch_field_with_alt_value(fields, 'std_score')
        result_row = {}

        # --- Individual results: ---
        if scores_hash[:name] == 'results'
          putc('i')
          # Build-up event title so that the Parser::EventType can detect them
          # for the MacroSolver later on:
          gender_code = fields.fetch(GENDER_FIELD_NAME, '').gsub(/D/i, 'F').gsub(/U/i, 'M')
          event_title = Parser::EventType.normalize_event_title("#{event_length} #{event_style}")
          result_row = {
            'pos' => rank,
            'name' => fields.fetch('swimmer_name', '').upcase,
            'year' => fetch_field_with_alt_value(fields, 'year_of_birth'),
            'sex' => gender_code,
            'team' => team_name,
            'timing' => timing,
            'score' => score
          }

          # --- Relay results: ---
          # TODO: Missing gender info from FINA Scores section => can't process this case
          # elsif scores_hash[:name] == 'rel_team'
          #   putc('r')
          #   # ASSUME: fixed 4x relay event, gender unknown
          #   event_title = "4x#{event_length} #{event_style}"
          #   # (Can't build a new section w/o knowing the gender)
          #   result_row = {
          #     'relay' => true,
          #     'pos' => rank,
          #     'team' => team_name,
          #     'timing' => timing,
          #     'score' => score
          #   }
        end
        # (Ignore any other unsupported contexts at this depth level)

        find_or_create_event_section_and_merge(resulting_sections, event_title:, category_code:, gender_code:, result_row:) if result_row.present?
        # ^^ Note that result_row won't be added to any section if title, category or gender are still unknown
      end

      puts('')
      resulting_sections
    end

    # Builds up the "stats" section that will hold the overall statistics rows for
    # the whole Meeting (when present).
    def create_stats_section(event_hash)
      return unless event_hash.is_a?(Hash)

      section = {
        'title' => 'Overall Stats',
        'stats' => true, # Commodity flag used by the MacroSolver
        'rows' => []
      }
      event_hash.fetch(:rows, [{}]).each do |ranking_hash|
        # Ignore unsupported contexts at this depth level:
        next unless ranking_hash[:name] == 'stats'

        section['rows'] << {
          'stats_label' => ranking_hash.fetch(:fields, {})['stats_label'],
          'stats_value' => ranking_hash.fetch(:fields, {})['stats_value']
        }
      end

      section
    end
    #-- -----------------------------------------------------------------------
    #++

    # Tries to reconstruct either the year of birth or the gender of a swimmer.
    # If year_of_birth or gender_code are missing, this will in turn:
    #
    # 1. scan already parsed results in search of a matching swimmer & team tuple, hoping
    #    the different event will show the missing fields;
    # 2. resort to DB finders if no matches are found for the gender (slow but accurate);
    # 3. use an educated guess with the name to detect the gender (it's ~75% accurate) when nothing
    #    else works.
    #
    # Note that if the year of birth is missing, there's nothing we can do to even make a plausible
    # guess for the age when the category is missing from the event (too many same-named swimmers in some cases).
    #
    # == Params:
    # - swimmer_name  => complete name of the swimmer (*MUST* be present);
    # - year_of_birth => year of birth of the swimmer; 2-digits years will be fixed internally;
    # - gender_code   => gender of the swimmer (M/F) coming from current category, if available;
    # - team_name     => team name of the swimmer;
    #
    # == Returns:
    # The same array of fields as the parameters minus the team name, with any missing or incomplete field
    # substituted with the values found elsewhere (including the swimmer name):
    #
    #   [swimmer_name, year_of_birth, gender_code]
    #
    def scan_results_or_search_db_for_missing_swimmer_fields(swimmer_name, year_of_birth, gender_code, team_name)
      # Scan existing swimmers in results searching for missing fields:
      # DEBUG ----------------------------------------------------------------
      # binding.pry if (year_of_birth.to_i.zero? || gender_code != 'F') && swimmer_name.starts_with?('*** ')
      # ----------------------------------------------------------------------

      # ** 1. ** Try to fix missing data searching already parsed results (in-file):
      if year_of_birth.to_i.zero? || gender_code.blank?
        scanned_year_of_birth, scanned_gender_code = search_result_row_with_swimmer(swimmer_name, team_name)
        year_of_birth = scanned_year_of_birth if scanned_year_of_birth.present? && year_of_birth.to_i.zero?
        gender_code = scanned_gender_code if scanned_gender_code.present? && gender_code.blank?
      end
      year_of_birth = adjust_2digit_year(year_of_birth) if year_of_birth.present? # (no-op if the year is already 4-digits)

      # ** 2. ** Try to fix missing data searching on the DB:
      # OLD IMPLEMENTATION:
      # Whenever the gender or the year of birth are still unknown, use the DB finders as second-last resort:
      # if year_of_birth.to_i.zero? || gender_code.blank?
      #   # Don't add nil params to the finder cmd as they may act as filters as well:
      #   finder_opts = { complete_name: swimmer_name }
      #   finder_opts[:year_of_birth] = year_of_birth.to_i if year_of_birth.to_i.positive?
      #   finder_opts[:gender_type_id] = GogglesDb::GenderType.find_by(code: gender_code).id if gender_code.present?
      #   cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Swimmer, finder_opts)
      #   if cmd.successful?
      #     gender_code = cmd.result.male? ? 'M' : 'F'
      #     year_of_birth = cmd.result.year_of_birth
      #     swimmer_name = cmd.result.complete_name

      # [UPDATE 20241204] Use a custom finder with a more strict bias (otherwise the result may overwrite the parsed data from relays,
      # which often lack both year of birth & gender info) and DON'T USE the DB FINDERS if we don't know the age:
      if year_of_birth.to_i.positive? && gender_code.blank?
        finder_opts = { complete_name: swimmer_name, year_of_birth: year_of_birth.to_i }
        finder = GogglesDb::DbFinders::BaseStrategy.new(GogglesDb::Swimmer, finder_opts, :for_name, 0.92) # Orig. bias: 0.8
        finder.scan_for_matches
        finder.sort_matches
        result = finder.matches.first&.candidate
        if result.present?
          gender_code = result.male? ? 'M' : 'F'
          year_of_birth = result.year_of_birth
          swimmer_name = result.complete_name
        else
          # As a very last resort, make an educated guess for the gender from the name, using common locale-IT exceptions:
          gender_code = if swimmer_name.match?(/\w+[nosl\-]\s?maria|andrea?$|one$|riele$|pasquale|fele$|oele$|luca|nicola$|\w+[gkcnos]'?$/ui)
                          'M'
                        else
                          # DEBUG ----------------------------------------------------------------
                          # binding.pry
                          # ----------------------------------------------------------------------
                          # raise('WARNING: MAKE SURE THE FORMAT FILE IS CORRECT! Are you sure you want to give a default gender to a swimmer?')
                          # (Sadly sometimes there's not enough data to make a decision. So we're going with the default...)
                          'F'
                        end
          # (Leave year_of_birth unset - can't do much in this case: this may raise an error later on if no further checks
          #  will be performed.)
        end
      end

      [swimmer_name&.upcase, year_of_birth, gender_code]
    end

    # Converts the indiv. result data structure into an Array of data Hash rows
    # storable into an L2 format Hash, assuming the supplied result_hash is indeed
    # supported and has the expected fields. This will also extract lap & delta timings when present.
    # Returns an empty Hash otherwise.
    #
    # == Example *source* DAO Hash structure from '1-ficr1':
    # - 🌀: repeatable
    #
    # +-- event 🌀
    #     [:rows]
    #       +-- category 🌀
    #           [:rows]
    #             +-- results 🌀
    #             +-- disqualified
    #
    # == Example *source* DAO Hash structure from '2-goswim1':
    #
    # +-- event 🌀 (includes 'cat_title' & 'gender_type' fields)
    #     [:rows]
    #       +-- results 🌀
    #           [:rows]
    #             +-- results_ext|results_ext_x2|results_ext_x3 (all DSQ desc labels)
    #
    def extract_indiv_result_fields(result_hash, cat_gender_code)
      # DEBUG ----------------------------------------------------------------
      # binding.pry if result_hash['swimmer_name'].to_s.include?('*** ') || result_hash[:fields]['swimmer_name'].to_s.include?('*** ')
      # ----------------------------------------------------------------------

      return {} unless IND_RESULT_SECTION.include?(result_hash[:name]) ||
                       result_hash[:name] == 'disqualified'

      # Example of a 'result' source Hash:
      # {
      #   :name=>"results", :key=>"...",
      #   :fields =>
      #   {"rank"=>"4", # / "SQ" for DSQ / "RT" for "Retired"
      #     "swimmer_name"=>"STAMINCHIA BOBERTO",
      #     "lane_num"=>"4",
      #     "nation"=>"ITA",
      #     "heat_rank"=>"2" # / "SQ" for DSQ
      #     "lap50"=>"33.52",
      #     "lap100"=>"1:10.27",
      #     "lap150"=>nil,
      #     "lap200"=>nil,
      #     [...]
      #     "timing"=>"1:10.27",
      #     "team_name"=>"FLAMENCO DANCING CLUB",
      #     "year_of_birth"=>"1968",
      #     "delta100"=>"36.75",
      #     "delta150"=>nil,
      #     "delta200"=>nil,
      #     [...]
      #     "disqualify_type"=>"Falsa Partenza", # for DSQ only
      #     "std_score"=>"863,81"},
      #   :rows=>[]
      # }
      fields = result_hash.fetch(:fields, {})
      rank = fields['rank']&.delete(')')
      year_of_birth = fetch_field_with_alt_value(fields, 'year_of_birth')
      swimmer_name = extract_nested_field_name(result_hash, SWIMMER_FIELD_NAMES).to_s.upcase
      # Bail out if we don't have at least a swimmer name to check for:
      return {} if swimmer_name.blank?

      team_name = extract_nested_field_name(result_hash, TEAM_FIELD_NAMES)
      timing = format_timing_value(fetch_field_with_alt_value(fields, 'timing'))
      # Additional DSQ label ('disqualify_type' field inside a nested 'dsq_label' row):
      dsq_label = extract_additional_dsq_labels(result_hash) if rank.to_i.zero? || timing.blank?
      rank = nil if dsq_label.present? || timing.blank? # Force null rank when DSQ

      # Don't even consider 'X' as a possible default gender, since we're dealing with swimmers
      # and not with categories of events:
      cat_gender_code = nil unless cat_gender_code&.upcase == 'F' || cat_gender_code&.upcase == 'M'
      # Support gender codes inline on result rows (give priority to inner-depth contexts):
      gender_code = fields[GENDER_FIELD_NAME] || cat_gender_code
      # DEBUG ----------------------------------------------------------------
      # binding.pry if (year_of_birth.to_i.zero? || gender_code != 'F') && swimmer_name.starts_with?('*** ')
      # ----------------------------------------------------------------------
      swimmer_name, year_of_birth, gender_code = scan_results_or_search_db_for_missing_swimmer_fields(swimmer_name, year_of_birth, gender_code, team_name)

      {
        'pos' => rank,
        'name' => swimmer_name,
        'year' => year_of_birth,
        'sex' => gender_code,
        # TODO: support this in MacroSolver:
        'badge_num' => fetch_field_with_alt_value(fields, 'badge_num'),
        # Sometimes the 3-char region code may end up formatted in a second result row:
        # (TOS format: uses 2 different field names depending on position so the nil one doesn't overwrite the other)
        'badge_region' => fetch_field_with_alt_value(fields, 'badge_region'),
        'team' => team_name,
        'timing' => timing,
        'score' => fetch_field_with_alt_value(fields, 'std_score'),
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        'heat_rank' => fields['heat_rank'],
        'nation' => fields['nation'],
        'disqualify_type' => dsq_label,
        'rows' => []
      }.merge(extract_nested_lap_timings(result_hash)).compact
    end

    # Converts the relay result data structure into an Array of data Hash rows
    # storable into an L2 format Hash, assuming the supplied result_hash is indeed
    # supported and has the expected fields.
    # This will also join individual swimmer laps & delta timings into the resulting
    # row Hash when present.
    #
    # Returns the relay result row hash, with all relay swimmers & lap timings in it,
    # if the specified Hash can be processed somehow. (Must be a 'rel_team' kind of Hash.)
    # Returns {} otherwise.
    #
    # == Example *source* DAO Hash structure (from '1-ficr1.4x100'):
    # - 🌀: repeatable
    #
    # +-- event 🌀
    #     [:rows]
    #       +-- rel_category
    #       +-- rel_team 🌀
    #           [:rows]
    #             +-- rel_swimmer 🌀
    #             +-- disqualified
    #
    def extract_relay_result_fields(rel_team_hash) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
      return {} unless REL_RESULT_SECTION.include?(rel_team_hash[:name])

      fields = rel_team_hash.fetch(:fields, {})
      rank = fields['rank']&.delete(')')
      team_name = extract_nested_field_name(rel_team_hash, TEAM_FIELD_NAMES)
      timing = format_timing_value(fetch_field_with_alt_value(fields, 'timing'))
      # Additional DSQ label ('disqualify_type' field inside a nested 'dsq_label' row):
      dsq_label = extract_additional_dsq_labels(rel_team_hash) if rank.to_i.zero? || timing.blank?
      rank = nil if dsq_label.present? || timing.blank? # Force null rank when DSQ

      row_hash = {
        'relay' => true,
        'pos' => rank,
        'team' => team_name,
        'timing' => timing,
        'score' => fetch_field_with_alt_value(fields, 'std_score'),
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        'nation' => fields['nation'],
        'disqualify_type' => dsq_label
      }

      # Add lap & delta fields only when present in the source fields and resemble a timing value:
      (1..30).each do |idx|
        key = "lap#{idx * 50}"
        value = fetch_field_with_alt_value(fields, key)
        row_hash[key] = format_timing_value(value) if POSSIBLE_TIMING_REGEXP.match?(value)

        key = "delta#{idx * 50}"
        value = fetch_field_with_alt_value(fields, key)
        row_hash[key] = format_timing_value(value) if POSSIBLE_TIMING_REGEXP.match?(value)
      end
      # DEBUG ----------------------------------------------------------------
      # binding.pry if row_hash['timing'] == "01'43\"22"
      # ----------------------------------------------------------------------

      # Add relay swimmer laps onto the same result hash & compute possible age group
      # in the meantime (SOURCE: fields |=> DEST.: row_hash):
      row_hash['overall_age'] = fields['overall_age'].to_i # Make sure overall_age is initialized with an integer value in any case
      sum_overall_age = row_hash['overall_age'].zero?      # Don't compute overall age if the field is already present in the data hash

      # *** Same-depth case 1 (GoSwim-type): relay swimmer fields inside 'rel_team' ***
      8.times do |idx|
        next unless fields.key?("swimmer_name#{idx + 1}")

        # Extract swimmer name, year or gender (when available; look also at same row_hash depth for all fields):
        process_relay_swimmer_fields(idx + 1, fields, row_hash, sum_overall_age:)
      end

      rel_team_hash.fetch(:rows, [{}]).each_with_index do |rel_swimmer_hash, idx|
        # *** Nested case 1 (Ficr-type): 'rel_team' -> 'rel_swimmer' sub-row ***
        if REL_SWIMMER_SECTION.include?(rel_swimmer_hash[:name])
          swimmer_fields = rel_swimmer_hash.fetch(:fields, {})
          # Extract swimmer name, year or gender (when available):
          process_relay_swimmer_fields(idx + 1, swimmer_fields, row_hash, sum_overall_age:)

        # *** Nested case 2 (Ficr-type): DSQ label nested for swimmers in relays ***
        # Support also for 'disqualify_type' field inside nested row: 'rel_team' -> 'rel_dsq' sub-row
        elsif rel_swimmer_hash[:name] == 'rel_dsq' && rel_swimmer_hash.fetch(:fields, {})['disqualify_type'].present?
          # Precedence on swimmer DSQ labels over any other composed DSQ label found at team level:
          row_hash['disqualify_type'] = rel_swimmer_hash.fetch(:fields, {})['disqualify_type']
        end
      end

      row_hash.compact
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the complete Hash result in "L2" structure obtained from the DAO hierarchy
    # starting from this node.
    #
    # == Typical usage:
    #
    #   > str = l2.to_hash.to_json
    #   > File.open('path/to/json_results/my-output.json', 'w+') { |f| f.puts(str) }
    #
    # The resulting JSON file can be processed as usualy by a MacroSolver instance.
    #
    def to_hash
      result = header
      result['sections'] = event_sections
      result
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # ** Example data [header] structure from '1-ficr': **
    #
    # data =
    # {:name=>"header",
    #  :key=>"13|MEMORIAL “RUSCO E BRUSCO“|ROMA|18/12/2022",
    #  :fields=>{"edition"=>"13", "meeting_name"=>"MEMORIAL “RUSCO E BRUSCO“",
    #            "meeting_place"=>"ROMA", "meeting_date"=>"18/12/2022"},
    #  :rows=>
    #   [{:name=>"event",
    #     :key=>"100|Farfalla|Riepilogo",
    #     :fields=>{"event_length"=>"100", "event_type"=>"Farfalla", "event_sub_hdr"=>"Riepilogo"},
    #     :rows=>
    #      [{:name=>"category",
    #        :key=>"M55 Master Maschi 55 - 59",
    #        :fields=>{},
    #        :rows=>
    #         [{:name=>"rel_team",
    #           :key=>"4|GINOTTI PINO|4|ITA|33.52|1:10.27|1:10.27|NUMA OSTILIO SPORTING CLUB|1968|36.75|863,81",
    #           :fields=> [...]
    #
    #
    # ** Example data [header]->[post_header] structure from '2-goswim': **
    #
    # data = {:name=>"header",
    #  :key=>"Campionati Regionali Master Emilia|Romagna 2020",
    #  :fields=>{"edition"=>nil, "meeting_name"=>"Campionati Regionali Master Emilia", "meeting_name_ext"=>"Romagna 2020"},
    #  :rows=>
    #   [{:name=>"post_header", :key=>"Forli|16/02/2020|25", :fields=>{"meeting_place"=>"Forli", "meeting_date"=>"16/02/2020", "pool_type"=>"25"}, :rows=>[]},
    #    {:name=>"event",
    #     :key=>"4X50|4X50|MIST|MASTER 200-239",
    #     :fields=>{"event_length"=>"4X50", "event_type"=>"4X50", "gender_type"=>"MIST", "cat_title"=>"MASTER 200-239"},
    #     :rows=>
    #      [{:name=>"rel_team", [...]
    #-- -----------------------------------------------------------------------
    #++

    # Returns the fields Hash for the 'header', according to the detected supported structure.
    # (Flat fields all under header or nested in a 'post_header' row).
    # The returned field Hash will have all header fields at the same depth level.
    def extract_header_fields
      field_hash = @data.fetch(:fields, {})
      # Add the post header when present:
      post_header = @data.fetch(:rows, [{}])&.find { |h| h[:name] == 'post_header' }
      field_hash.merge!(post_header[:fields]) if post_header.present? && post_header.key?(:fields)
      # Join the name extension to the meeting_name when present:
      field_hash['meeting_name'] = [field_hash['meeting_name'], field_hash['meeting_name_ext']].join(' ') if field_hash['meeting_name_ext'].present?
      field_hash
    end

    # Gets the Meeting name from the data Hash, if available; defaults to an empty string.
    def fetch_meeting_name
      field_hash = extract_header_fields
      return "#{field_hash['edition']}° #{field_hash['meeting_name']}" if field_hash['edition'].present?

      field_hash['meeting_name']
    end

    # Gets the Meeting session date, if available. Returns nil when not found.
    #
    # == Params:
    # - field_hash: the :fields Hash extracted from any data row
    #
    # == Returns:
    # The value found or +nil+ when none.
    def fetch_session_date(field_hash)
      field_hash&.fetch('meeting_date', nil) || field_hash&.fetch('meeting_venue_or_date', nil)
    end

    # Gets the Meeting session place, if available. Returns nil when not found.
    #
    # == Params:
    # - field_hash: the :fields Hash extracted from any data row
    #
    # == Returns:
    # The value found or +nil+ when none.
    def fetch_session_place(field_hash)
      field_hash&.fetch('meeting_place', nil)
    end

    # Returns the pool total lanes (first) & the length in meters (last) as items
    # of an array of integers when the 'pool_type' field is found in the footer.
    # Returns an empty array ([]) otherwise.
    #
    # == Params:
    # - field_hash: the :fields Hash extracted from any data row
    #
    # == Returns:
    # The [lanes_tot, pool_type_len] array when found.
    def fetch_pool_type(field_hash)
      pool_type_len = field_hash&.fetch('pool_type', '')
      return [nil, pool_type_len] if pool_type_len.present?

      # Hard-fallback: search in footer, as in 1-ficr1

      # Structure from 1-ficr1:
      #   data => header
      #     data[:rows] => event
      #       data[:rows].first[:rows] => category || footer
      footer = @data.fetch(:rows, [{}]).first&.[](:rows)&.find { |h| h[:name] == 'footer' }

      # Supported footer example:
      # {:name=>"footer", :key=>"8 corsie 25m|Risultati su https://...",
      #  :fields=>{"pool_type"=>"8 corsie 25m",
      #            "page_delimiter"=>"Risultati su https://..."}, :rows=>[]}

      footer&.fetch(:fields, {})&.fetch('pool_type', '').to_s.split(' corsie ').map(&:to_i)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds the event title given the data Hash of an event.
    # Returns an array that includes both the composed title and all its elements
    # as strings:
    #
    #   [<event_title>, <length>, <event_type_name>, <gender_type_char>]
    #
    # 'gender_type_char' can be 'M', 'F' or 'X' (intermixed relay)
    #
    # If the 'length' string includes also an 'X' (either upcase or lowercase)
    # it's a relay event.
    def fetch_event_title(event_hash)
      raise 'Not an Event hash!' unless event_hash.is_a?(Hash) && event_hash[:name] == 'event'

      # Example structure:
      # {:name=>"event",
      #  :key=>"4X100|Stile libero|Misti|Riepilogo",
      #  :fields=>{
      #     "event_length"=>"4X100", "event_type"=>"Stile libero",
      #     "gender_type"=>"Misti"
      #     "event_sub_hdr"=>"Riepilogo"
      #  },
      #  :rows=>
      #   [{:name=>"category"|"rel_category",
      #     :key=>...,
      length = event_hash.fetch(:fields, {})&.fetch('event_length', '')
      type = event_hash.fetch(:fields, {})&.fetch('event_type', '')
      gender = event_hash.fetch(:fields, {})&.fetch(GENDER_FIELD_NAME, '')
      # Return just the first gender code char:
      gender = intermixed_gender_label?(gender) ? GogglesDb::GenderType.intermixed.code : gender.to_s.at(0)&.upcase

      ["#{length} #{type}", length, type, gender]
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns +true+ if the supplied text seems to describe an intermixed-gender type of event;
    # +false+ otherwise.
    def intermixed_gender_label?(gender_text)
      /mist|maschi\se\sfemmine|m\+f/i.match?(gender_text.to_s)
    end

    # Returns +true+ only if the supplied row_hash seems to support and
    # store a string value representing a possible CategoryType code only for individual results.
    def holds_category_type?(row_hash)
      row_hash.is_a?(Hash) &&
        ((row_hash[:name] == 'category') ||
         (row_hash.fetch(:fields, {}).key?(CAT_FIELD_NAME) &&
          !row_hash.fetch(:fields, {})['event_length'].to_s.match?(/X/i)))
    end

    # Gets the indiv. result category code directly from the given data hash key or the supported
    # field name if anything else fails.
    # Estracting the code from the key value here is more generic than relying on
    # the actual field names. Returns +nil+ for any other unsupported case.
    def fetch_category_code(row_hash)
      # *** Context 'category'|'event' ***
      # (Assumed to include the "category title" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '')
      # As of 2023 (season 232+) FIN lowered the bar and introduced the new "M20" & "U20" age groups:
      under_limit = @season.begin_date.year > 2022 ? 20 : 25

      # key type 1, example: [...]"M55 Master Maschi 55 - 59"[...]
      if /\s*([UAM]\d{2})(?>\sUnder|\sMaster)?\s(?>Femmine|Maschi)/ui.match?(key)
        /\s*([UAM]\d{2})(?>\sUnder|\sMaster)?\s(?>Femmine|Maschi)/ui.match(key).captures.first

      # key type 2, example: "...|(Master \d\d)|..."
      elsif /\|((?>Master|Under|Amatori|Propaganda)\s\d{2})\|/ui.match?(key)
        /\|((?>Master|Under|Amatori|Propaganda)\s\d{2})\|/ui.match(key).captures
                                                            .first.to_s
                                                            .gsub(/Master\s/i, 'M')
                                                            .gsub(/Under\s/i, 'U')
                                                            .gsub(/Propaganda\s?/i, 'A')
                                                            .gsub(/Amatori\s/i, 'A')

      # key type 3, example: "...<gender>|(\d\d)\s?-\s?\d\d" => M/U<dd>
      elsif /\|(\d{2})\s?-\s?\d{2}/ui.match?(key)
        age_slot = /\|(\d{2})\s?-\s?\d{2}/ui.match(key).captures.first
        age_slot.to_i >= under_limit ? "M#{age_slot}" : "U#{age_slot}"

      # use just the field value "almost as-is" for unsupported key value cases:
      elsif row_hash.key?(:fields) && row_hash[:fields].key?(CAT_FIELD_NAME)
        result = row_hash[:fields][CAT_FIELD_NAME].to_s
                                                  .gsub(/Master\s?/i, 'M')
                                                  .gsub(/Under\s?/i, 'U')
                                                  .gsub(/Propaganda\s?/i, 'A')
                                                  .gsub(/Amatori\s?/i, 'A')
                                                  .gsub(/\s/i, '')
        # Handle special FVG layout "cat_title" format (age without "M" or "U"):
        return "M#{result}" if result.match?(/^\d{2}$/i) && result.to_i >= under_limit
        return 'U25' if result.match?(/^\d{2}$/i) && under_limit == 25 # Ignore non-stadard age groups for older seasons

        result
      end
    end

    # Returns +true+ only if the supplied row_hash seems to support and
    # store a string value representing a possible CategoryType code
    # for relays or a relay result (which may include the category too).
    def holds_relay_category_or_relay_result?(row_hash)
      row_hash.is_a?(Hash) &&
        (CATEGORY_SECTION.include?(row_hash[:name]) || REL_RESULT_SECTION.include?(row_hash[:name]) ||
         row_hash.fetch(:fields, {}).key?(CAT_FIELD_NAME))
    end

    # Gets the relay result category code directly from the given data hash key or the supported
    # field name if anything else fails.
    #
    # The implementation extracts the code from the key value because it's more generic
    # than relying on the actual field names (which, by the way, it's usually 'cat_title').
    #
    # Captures just "<age1>[\s?-\s?<age2>]"
    # Supported examples for key string relevant part:
    #   "M 200 - 239 Master Femmine", "M 200-239 Master Femmine"
    #   "M200 Master Maschi", "M 200 Master Misti"
    #   "Master Maschi M200 - 239", "Master Maschi M200-239"
    #   "M 200 - 239, M200", "M 200-239"
    #   "Master Maschi 200 - 239", "200-239 Master Misti"
    #   "M200 Femminile"
    #
    # Returns +nil+ for any other unsupported case.
    def fetch_rel_category_code(row_hash)
      # *** Context 'rel_category' ***
      # (Assumed to include the "category title" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '')

      regexp = /
        \b
        (?>(?>M(?>aster)?|A(?>ssoluti)?|U(?>nder)?)\s?)?
        (?>(?>Misti|Femmin\w*|Masch\w*)?\s)?
        (\d{2,3}\s?-\s?\d{2,3}|[MAU]\s?\d{2,3}(?>\s?-\s?\d{2,3})?)
        (?>(?>M(?>aster)?|A(?>ssoluti)?|U(?>nder)?)\s)?
        (?>Misti|Femmin\w*|Masch\w*)?
        \b
      /uxi
      return unless regexp.match?(key)

      regexp.match(key).captures.first.delete(' ').upcase.delete('M').delete('A').delete('U')

      # Old implementation:
      # Example key 1 => "Master Misti 200 - 239"
      # case key
      # when /(?>Under|Master)\s(?>Misti|Femmin\w*|Masch\w*)(?>\s(\d{2,3}\s?-\s?\d{2,3}))?/ui
      #   /(?>Under|Master)\s(?>Misti|Femmin\w*|Masch\w*)(?>\s(\d{2,3}\s?-\s?\d{2,3}))?/ui.match(key).captures&.first&.delete(' ')

      # # Example key 2 => "(M(ASTER))?\s?<age1>\s?-\s?<age2>" => "M100-119...", "M 100 - 119...", "100 - 119"
      # when /[UAM]?(?>ASTER)?\s?(\d{2,3}\s?-\s?\d{2,3})/ui
      #   # Return a valid age-group code for relays ("<age1>-<age2>"):
      #   /[UAM]?(?>ASTER)?\s?(\d{2,3}\s?-\s?\d{2,3})/ui.match(key).captures&.first&.delete(' ')
      # end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Gets the individual category gender code as a single char, given its source data hash (if found).
    # Returns +nil+ otherwise.
    def fetch_category_gender(row_hash)
      return unless row_hash.is_a?(Hash)

      # *** Context 'category'|'event' ***
      # (Assumed to include the "gender type label" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '').gsub(/donne/i, 'femmine').gsub(/uomini/i, 'maschi')
      # Return gender unknown when the key value doesn't specify a unique gender:
      return if /Maschi\se\sFemmine/ui.match?(key) # (i.e.: "Niangara" layouts, w/o explicit category & gender labels)

      # key type 1, example: [...]"M55 Master Maschi 55 - 59"[...]
      if /\s*[UAM]\d{2}(?>\sUnder|\sMaster)?\s(Femmine|Maschi)/ui.match?(key)
        /\s*[UAM]\d{2}(?>\sUnder|\sMaster)?\s(Femmine|Maschi)/ui.match(key).captures.first.upcase.at(0)

      # key type 2, example: "...|(masch\w+|femmin\w+)\|..." (more generic)
      elsif /\|(masch\w*|femmin\w*)\|/ui.match?(key)
        /\|(masch\w*|femmin\w*)\|/ui.match(key).captures.first.upcase.at(0)

      # use just the first capital character from the field value:
      elsif row_hash.key?(:fields) && row_hash[:fields].key?(GENDER_FIELD_NAME)
        row_hash[:fields][GENDER_FIELD_NAME].to_s.gsub(/donne/i, 'femmine').gsub(/uomini/i, 'maschi').upcase.at(0)
      end
    end

    # Gets the relay category gender code as a single char, given its source data hash (if found).
    # Returns +nil+ otherwise or for an unsupported category Hash.
    def fetch_rel_category_gender(row_hash)
      return unless row_hash.is_a?(Hash) && CATEGORY_SECTION.include?(row_hash[:name])

      # *** Context 'rel_category'|'rel_team'|'event' ***
      key = row_hash.fetch(:key, '')

      gender_name = case key
                    when /(?>Under|Master)\s(Mist\w|Femmin\w*|maschi\se\sfemmine|Masch\w*)\s?(?>\d{2,3}\s-\s\d{2,3})?/ui
                      # Example key 1 => "Master Misti( 200 - 239)?"
                      /(?>Under|Master)\s(Mist\w|Femmin\w*|maschi\se\sfemmine|Masch\w*)\s?(?>\d{2,3}\s-\s\d{2,3})?/ui.match(key).captures.first

                    # Example key 2 => "{event_length: 'mistaffetta <4|6|8>x<len>'}|<style_name>|<mistaffetta|gender>|M(ASTER)?\s?<age1>-<age2>(|<base_time>)?"
                    when /\|(\w+)\|M(?>ASTER)?\s?\d{2,3}-\d{2,3}/ui
                      # Use as reference the valid age-group code for relays ("<age1>-<age2>")
                      # (ASSUMING the gender is *BEFORE* that):
                      /\|(\w+)\|M(?>ASTER)?\s?\d{2,3}-\d{2,3}/ui.match(key).captures.first

                    # Example key 3 => "M100-119|Masch|..."
                    when /M\d{2,3}-\d{2,3}\|(Masch|Femmin|Mist)/ui
                      /M\d{2,3}-\d{2,3}\|(Masch|Femmin|Mist)/ui.match(key).captures.first
                    end
      # Use the field value when no match is found:
      gender_name = row_hash[:fields][GENDER_FIELD_NAME] if gender_name.blank? && row_hash.key?(:fields) && row_hash[:fields].key?(GENDER_FIELD_NAME)
      return GogglesDb::GenderType.intermixed.code if intermixed_gender_label?(gender_name)

      gender_name&.at(0)&.upcase
    end
    #-- -----------------------------------------------------------------------
    #++

    # Given 3 data-hash structure (directly from the internal @data member) at 3 possible
    # different hierarchy depth levels, with these priorities:
    #
    # 1. 'results' context data (higher)
    # 2. 'category' context data
    # 3. 'event' context data (lower)
    #
    # The methods returns the first parent category code and gender code found at any depth.
    # (Even when each one is a at different depth.)
    # Supports default values for the category and gender codes assigned when no value is found.
    #
    # == Options:
    # - <tt>event:</tt>         => the 'event' context data hash (can be +nil+)
    # - <tt>category:</tt>      => the 'category' context data hash (can be +nil+)
    # - <tt>result:</tt>        => the 'results' context data hash (can be +nil+)
    # - <tt>def_category:</tt>  => the default category code to be used if none is found
    # - <tt>def_gender:</tt>    => the default gender code to be used if none is found
    # - <tt>relay:</tt>         => +true+ if the event is a relay; +false+ otherwise (default)
    #
    # Each hash can also be +nil+ if not available.
    #
    # == Returns:
    # The array: [category_code, gender_code]
    #
    def fetch_best_category_and_gender_codes_from_any_depth(options = {})
      event = options[:event] || {}
      category = options[:category] || {}
      result = options[:result] || {}
      def_category = options[:def_category]
      def_gender = options[:def_gender]
      relay = options[:relay] == true

      category_code = if relay
                        fetch_rel_category_code(result) || fetch_rel_category_code(category) || fetch_rel_category_code(event) || def_category
                      else
                        fetch_category_code(result) || fetch_category_code(category) || fetch_category_code(event) || def_category
                      end
      gender_code = if relay
                      fetch_rel_category_gender(result) || fetch_rel_category_gender(category) || fetch_rel_category_gender(event) || def_gender
                    else
                      fetch_category_gender(result) || fetch_category_gender(category) || fetch_category_gender(event) || def_gender
                    end

      [category_code, gender_code]
    end
    #-- -----------------------------------------------------------------------
    #++

    # Retrieves the first present value for the 'field_name' specified whenever this
    # has been also stored with an "_alt" suffix.
    # == Params:
    # - field_hash: the :fields Hash storing each field with its value
    # - field_name: the String field name to retrieve
    # == Returns:
    # The value or "alt" found for the specified field.
    def fetch_field_with_alt_value(field_hash, field_name)
      field_hash[field_name] || field_hash["#{field_name}_alt"]
    end

    # Returns the fully composed field value considering also any possibly additional name part or label
    # stored in any of the sub-rows nested at the first level of the current/parent result_hash specified.
    # The name of the sibling row shouldn't matter as each nested row is scanned in search for supported
    # column names only.
    #
    # Returns +nil+ when no values or valid field names are found (searching also at the "root" level
    # of the result_hash).
    #
    # This method automatically supports "_alt" field names when the default field names are not found.
    # In other words, the supported field name list will be scanned 4 times in the following order:
    # 1. default field names at root level;
    # 2. default field names at sibling level;
    # 3. "_alt" field names at root level (when no values from the default field names have been found);
    # 4. "_alt" field names at sibling level (when no values from the default field names have been found).
    def extract_nested_field_name(result_hash, supported_field_names)
      result_value = ''
      supported_field_names = [supported_field_names] if supported_field_names.is_a?(String)
      result_hash.fetch(:fields, {}).each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if supported_field_names.include?(fname) }

      # Check for any possible additional (& supported) fields that need to be collated into
      # a single swimmer name, which could be possibly stored inside sibling rows:
      result_hash.fetch(:rows, [{}]).each do |row_hash|
        next if row_hash[:fields].blank?

        row_hash[:fields].each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if supported_field_names.include?(fname) }
      end
      return result_value.strip if result_value.present?

      # Search for an "_alt" value when the default field names were not found:
      alt_field_names = supported_field_names.map { |name| "#{name}_alt" }
      result_value = ''
      result_hash.fetch(:fields, {}).each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if alt_field_names.include?(fname) }

      # Check for any possible additional (& supported) fields that need to be collated into
      # a single swimmer name, which could be possibly stored inside sibling rows:
      result_hash.fetch(:rows, [{}]).each do |row_hash|
        next if row_hash[:fields].blank?

        row_hash[:fields].each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if alt_field_names.include?(fname) }
      end
      result_value.present? ? result_value.strip : nil
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans the sibling rows of the specified result_hash searching for <lapXXX> or <deltaXXX> fields.
    #
    # Returns an Hash with all collected fields (starting at zero-depth level).
    # As usual, whenever a field is defined with the same name in more than one place or depth level,
    # the last value found will overwrite anything found first.
    # Fields at zero/root level found in the result_hash have the priority.
    def extract_nested_lap_timings(result_hash)
      result = {}
      root_fields = result_hash.fetch(:fields, {})
      rows = result_hash.fetch(:rows, []).map { |row| row.fetch(:fields, {}) } << root_fields

      # For each sibling row, consider just its fields and collect all matching names in the result:
      # (root fields last)
      rows.each do |row_fields|
        # Add lap & delta fields only when present in the current row:
        (1..30).each do |idx|
          key = "lap#{idx * 50}"
          value = fetch_field_with_alt_value(row_fields, key)
          result[key] = format_timing_value(value) if POSSIBLE_TIMING_REGEXP.match?(value)

          key = "delta#{idx * 50}"
          value = fetch_field_with_alt_value(row_fields, key)
          result[key] = format_timing_value(value) if POSSIBLE_TIMING_REGEXP.match?(value)
        end
      end
      result.compact
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns a single DSQ string label whenever the field 'disqualify_type' is present or
    # if there are any sibling DAO rows named 'dsq_label', 'dsq_label_ind', 'dsq_label_rel',
    # 'dsq_label_x2' or 'dsq_label_x3';
    # The additional rows are ignored if any of them contain a 'key' with a value.
    # Supports additional DSQ details stored in the 'fields' Hash (as 'dsq_details' key).
    # Returns +nil+ otherwise.
    #
    # == Notes:
    # 1. expected field name    => 'disqualify_type' || 'disqualify_type_alt';
    # 2. sub-row contexts names => 'dsq_label' or 'dsq_label_XXX' ('ind', 'rel', 'x2', 'x3') with a
    #                              meaningful key value.
    # 3. additional details     => 'dsq_details' (at "fields" level), appended to the extracted label value;
    #
    def extract_additional_dsq_labels(result_hash)
      dsq_label = result_hash.fetch(:fields, {})['disqualify_type'] || result_hash.fetch(:fields, {})['disqualify_type_alt'] || ''
      dsq_label += result_hash.fetch(:fields, {})['dsq_details'] if result_hash.fetch(:fields, {})['dsq_details'].present?
      timing = result_hash.fetch(:fields, {})['timing']
      # Check for any possible additional (up to 3x rows) DSQ labels added as sibling rows:
      # add any additional DSQ label value (grep'ed as string keys) when present.
      additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == 'dsq_label' }
      dsq_label = [dsq_label, additional_hash[:key]].compact.join if additional_hash&.key?(:key)
      %w[ind rel x2 x3].each do |suffix|
        additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == "dsq_label_#{suffix}" }
        dsq_label = [dsq_label, additional_hash[:key]].compact.join if additional_hash&.key?(:key)
      end
      # Assume the timing shall store the 'DSQ' label and use that only as last resort for label value:
      dsq_label = timing unless dsq_label.present? || timing.blank? || POSSIBLE_TIMING_REGEXP.match?(timing)
      # Bail out if no DSQ label was found so far:
      return if dsq_label.blank?

      # Make sure the timing field is cleared out when we have a DSQ label:
      result_hash[:fields]['timing'] = nil
      dsq_label
    end
    #-- -----------------------------------------------------------------------
    #++

    # Seeks any existing event-only section given its title, category string and gender string codes.
    #
    # == Params:
    # - <tt>array_of_sections</tt>  => Array of resulting PdfResults::L2EventSection items or ready-to-go Hash
    #                                  (this case, usually only for 'rankings' or 'stats' sections).
    #
    # - <tt>event_title</tt>        => title or name of the event as a String;
    #
    # - <tt>category_code</tt>      => String category code, possibly "normalized" (externally);
    #
    # - <tt>gender_code</tt>        => String gender code;
    #
    # == Returns:
    # The PdfResults::L2EventSection found or +nil+ otherwise.
    # Note that this method will always fail for 'rankings' and 'stats' sections hashes.
    #
    def find_existing_event_section(array_of_sections, event_title, category_code, gender_code)
      return unless array_of_sections.is_a?(Array) && array_of_sections.present? && event_title.present?

      section_to_be_found = PdfResults::L2EventSection.new(event_title:, category_code:, gender_code:, categories_cache: @categories_cache)
      array_of_sections.find do |section|
        next unless section.is_a?(PdfResults::L2EventSection)

        section == section_to_be_found
      end
    end

    # Scans <tt>resulting_sections</tt> searching for an event section matching the specified parameters,
    # or creates one when not found, and adds the <tt>result_row</tt> to its "rows" array at the end.
    # (Result row will be added ONLY if all section "keys" are present: title, category & gender.)
    #
    # If the section is already found and the with any existing sibling rows,
    # the 'rows' scanned for a possible merge candidate matching the key fields of the <tt>result_row</tt>.
    #
    # For MIR result rows Hashes, merging keys to detect mergeable candidates are: 'name', 'team' & 'timing'.
    # For MRR result rows: just 'team' & 'timing'.
    #
    # === Note:
    # Since objects like an Hash are referenced in an array, updating directly the object instance
    # or a reference to it will make the referenced link inside the array be up to date as well.
    #
    # == Params:
    # - <tt>resulting_sections</tt>: the Array of event section Hash items yield by the translation loop;
    #   typically, in the "flattened" L2 format; each item is an event section Hash, holding several rows,
    #   with each item being a result row Hash (either for individual results or relays).
    #
    # - <tt>event_title</tt>: the string title for the event being processed;
    #   value of field "title" in the section being searched or added.
    #
    # - <tt>category_code</tt>: the string category code for the event being processed;
    #   value of field "fin_sigla_categoria" in the section being searched or added.
    #
    # - <tt>gender_code</tt>: the string gender code (1 char) for the event being processed;
    #   value of field "fin_sesso" in the section being searched or added.
    #
    # - <tt>result_row</tt>: result row Hash in L2 format, ready to be added to the "rows" array of the section being searched or added.
    #
    # == Returns:
    # +nil+ on no-op, the updated <tt>resulting_sections</tt> otherwise.
    #
    def find_or_create_event_section_and_merge(resulting_sections, event_title:, category_code:, gender_code:, result_row:)
      return if !resulting_sections.is_a?(Array) || !result_row.is_a?(Hash) ||
                event_title.blank? || category_code.blank? || gender_code.blank?

      # Fetch proper parent/event section with category:
      event_section = find_existing_event_section(resulting_sections, event_title, category_code, gender_code)

      # Add/MERGE rows from section_hash when a matching event section is found:
      if event_section.present? && event_section.complete?
        event_section.add_or_merge_results_in_rows(result_row)
      else
        new_section = PdfResults::L2EventSection.new(event_title:, category_code:, gender_code:, categories_cache: @categories_cache)
        new_section.add_or_merge_results_in_rows(result_row)
        resulting_sections << new_section
      end
    end

    # Finds or set the current parent event section. Works for both individual and relay results.
    # Allows to return a valid reference to a parent section coherent to the values specified
    # in the result data hash or in the <tt>parent_section</tt>, whichever is more complete.
    #
    # Current row results have precedence over the specified parent event section values
    # (especially if the row result contains valid category and gender codes).
    #
    # Used whenever the section header can be completed only later on during the translation process
    # (with gender & category values possibly changing every result row).
    #
    # == Params:
    # - <tt>resulting_sections</tt> => the array of result sections already processed so far;
    # - <tt>parent_section</tt>     => current parent PdfResults::L2EventSection being processed;
    #
    # - <tt>result_data_hash</tt>   => current result data Hash yet to be converted into L2 format
    #                                  or even a result_row flattened Hash already converted.
    #                                  (Works both ways, parent section won't be changed if the field keys aren't there.)
    # == Returns:
    # The array having as items:
    #
    #    [<correct_parent_section>, <recompute_ranking>]
    #
    # - <tt>correct_parent_section</tt> => a new or existing PdfResults::L2EventSection instance reference.
    # - <tt>recompute_ranking</tt>      => +true+ if the section was changed and the category ranking value must be recomputed;
    #                                      +false+ otherwise.
    def point_to_parent_section_according_to_current_result_data_hash(resulting_sections, parent_section, result_data_hash)
      # Give precedence to row values here:
      event_title     = parent_section.event_title
      # Override blank section keys with row hash field values (even nested):
      curr_cat_code   = extract_nested_field_name(result_data_hash, 'cat_title') || parent_section.category_code
      curr_cat_gender = extract_nested_field_name(result_data_hash, 'gender_type') || parent_section.gender_code

      # -- RELAY RES. -- (Override blank section keys with converted/computed result values for responding keys only)
      # Force category code update with post-computation only when not properly set (and we can compute it):
      curr_cat_code = post_compute_rel_category_code(result_data_hash['overall_age'].to_i) if curr_cat_code.blank? && result_data_hash['overall_age'].to_i.positive?

      # Force section gender code update only if not properly set (and extracted data from result row can help):
      if curr_cat_gender.blank? && result_data_hash.key?('gender_type1')
        genders = result_data_hash.keys.select { |k| k.start_with?('gender_type') }.uniq
        curr_cat_gender = genders.size > 1 ? 'X' : genders.first.upcase
      end

      # -- INVIDUAL RES. -- (Override blank section keys with converted/computed result values for responding keys only)
      # Force category code update with post-computation only when not properly set (and we can compute it):
      curr_cat_code = post_compute_ind_category_code(result_data_hash['year'].to_i) if curr_cat_code.blank?

      # Force section gender code update only if not properly set (and extracted data from result row can help):
      curr_cat_gender = result_data_hash['sex'].upcase if curr_cat_gender.blank? && result_data_hash['sex'].present?

      # Find an existing section or create a new reference to carry around the current category/gender codes
      # until we are ready to add the current result row to it:
      curr_section = find_existing_event_section(resulting_sections, event_title, curr_cat_code, curr_cat_gender) ||
                     PdfResults::L2EventSection.new(event_title:, category_code: curr_cat_code,
                                                    gender_code: curr_cat_gender, categories_cache: @categories_cache,
                                                    additional_fields: parent_section.additional_fields)

      # NOTE: with the assignment above there's only one case where we may lost the #additional_fields hash:
      # whenever the section is new but it doesn't get completed until the last depth level is reached and the row
      # result is currently added to it (and the section, in turn, gets added to the resulting list of sections).
      # Currently this is not that relevant to be covered as a case as the additional section fields are not stored into the DB.

      [curr_section, parent_section != curr_section]
    end

    # Sorts each <tt>resulting_sections</tt> item rows array by timing, recomputing also the rank value.
    # (Useful for results in event sections with an absolute ranking and without category split, after
    #  the proper category event sections have been created.)
    #
    # == Params:
    # - <tt>resulting_sections</tt> => the array of result sections already processed so far;
    #
    # == Returns:
    # The updated array of sections (in any case).
    #
    def recompute_ranking_for_each_event_section(resulting_sections)
      return resulting_sections unless resulting_sections.is_a?(Array)

      resulting_sections.each do |event_section|
        # Do not reorder empty sections or rankings or stats:
        next unless event_section.is_a?(PdfResults::L2EventSection) || (event_section.is_a?(PdfResults::L2EventSection) && event_section.rows.blank?) ||
                    (event_section.is_a?(Hash) && event_section['rows'].blank?)

        # 1. Sort event rows by timing
        event_section.rows.sort! do |row_a, row_b|
          val1 = Parser::Timing.from_l2_result(row_a['timing']) || Parser::Timing.from_l2_result("99'99\"00")
          val2 = Parser::Timing.from_l2_result(row_b['timing']) || Parser::Timing.from_l2_result("99'99\"00")
          val1 <=> val2
        end
        # 2. Recompute ranking:
        event_section.rows.each_with_index do |row_hash, index|
          row_hash['pos'] = row_hash['timing'].present? ? index + 1 : nil
        end
      end

      resulting_sections
    end

    # Detects the possible valid individual result category code given the year_of_birth of the swimmer.
    # Returns the string category code ("M<nn>") or +nil+ when not found.
    # == Params:
    # - year_of_birth: year_of_birth of the swimmer as integer
    def post_compute_ind_category_code(year_of_birth)
      return unless year_of_birth.positive?

      # Compute age and adjust in case the session falls into the first
      # half of the Championship year:
      age = @season.begin_date.year - year_of_birth + (session_month.to_i > 8 ? 1 : 0)
      curr_cat_code, _cat = @categories_cache.find_category_code_for_age(age, relay: false)
      # DEBUG ----------------------------------------------------------------
      # THIS MAY HAPPEN only when the categories lack a certain age range:
      binding.pry if curr_cat_code.blank?
      # FIX: need to add the missing category *before* the parsing, using a migration on the DB & Main projects
      # ----------------------------------------------------------------------
      curr_cat_code
    end

    # Detects the possible valid relay category code given the overall age of the involved swimmers.
    # Returns the string category code ("<nnn>-<nnn>") or +nil+ when not found.
    # == Params:
    # - overall_age: integer overall age, sum of the age of all relay swimmers found
    def post_compute_rel_category_code(overall_age)
      return unless overall_age.positive?

      curr_cat_code, _cat = @categories_cache.find_category_code_for_age(overall_age, relay: true)
      # DEBUG ----------------------------------------------------------------
      # THIS MAY HAPPEN only when the categories lack a certain age range:
      binding.pry if curr_cat_code.blank?
      # FIX: need to add the missing category *before* the parsing, using a migration on the DB & Main projects
      # THESE should be already there:
      # curr_cat_code = '80-99' if curr_cat_code.blank? && (80..99).cover?(overall_age) # U25 (2020+, out of race)
      # curr_cat_code = '60-79' if curr_cat_code.blank? && (60..79).cover?(overall_age) # U20 (2023+, out of race)
      # ----------------------------------------------------------------------
      curr_cat_code
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the specified timing_string formatted in a more standardized format (<MM'SS"HN>).
    # Can detect and adjust:
    # - misc "TOS" formats (<MM.SS.HN>, <MM SS HN>, <SS,HN>)
    # - misc "EMI" formats (<MM:SS:HN>, <MM:SS.HN>)
    def format_timing_value(timing_string)
      timing_string&.gsub(/^(\d{1,2})\D/, '\1\'')
                   &.gsub(/\D(\d{1,2})$/, '"\1')
    end

    # Adjusts any 2-digit year to the proper century using current Meeting's Season year.
    # Returns the year in 4-digit format.
    def adjust_2digit_year(year_of_birth)
      # 4-digit years are already ok:
      return year_of_birth.to_i if year_of_birth.to_s.length == 4
      # Consider masters up to a max age of 110 as born into the previous century:
      return year_of_birth.to_i + 1900 if @season.begin_date.year - 1900 - year_of_birth.to_i < 110

      year_of_birth.to_i + 2000
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans *all* result rows in search of the specified swimmer.
    # Used to retrieve any possible missing fields for a swimmer entity.
    #
    # == Params:
    # - swimmer_name: swimmer's full name
    # - team_name: swimmer's team name
    #
    # == Returns:
    # [<year_of_birth>, <gender_type>] or +nil+ when not found
    #
    def search_result_row_with_swimmer(swimmer_name, team_name)
      # DEBUG ----------------------------------------------------------------
      # binding.pry if swimmer_name.starts_with?(<swimmer_name>) && team_name.starts_with?(<team_name>)
      # ----------------------------------------------------------------------
      @data.fetch(:rows, [{}]).each do |event_hash|
        # Ignore other unsupported contexts at this depth level:
        next unless event_hash[:name] == 'event'

        # Set current searched gender from event when found
        _title, _length, _type, curr_gender_from_event = fetch_event_title(event_hash)
        # Don't even consider 'X' as a gender, since we're dealing with swimmers & not categories of events:
        curr_gender_from_event = nil if curr_gender_from_event&.upcase == 'X'

        event_hash.fetch(:rows, [{}]).each do |category_hash|
          # Return after first match
          result = category_hash.fetch(:rows, [{}])
                                .find do |row|
                                  fields = row.fetch(:fields, {})
                                  fields['swimmer_name']&.upcase == swimmer_name&.upcase &&
                                    fields['team_name']&.upcase == team_name&.upcase
                                end
          # Set current searched gender from event, category or current row result when found
          curr_gender = fetch_category_gender(category_hash) || curr_gender_from_event ||
                        result&.fetch(:fields, {})&.fetch('gender_type', nil)

          return [result.fetch(:fields, {})['year_of_birth'].to_i, curr_gender] if result.present?
        end
      end

      nil
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts the relay swimmer data fields into the "flattened" L2 hash format,
    # ready to be converted to JSON as result section.
    # Detects automatically if the swimmer data fields are using indexed fields
    # (i.e.: "swimmer_name<IDX>") or not. (This depends on context structure nesting.)
    #
    # == Params:
    # - swimmer_idx     => current relay swimmer index; 0 for dedicated 'rel_swimmer' contexts,
    #                      a positive number for swimmer data stored at the same depth level as the team;
    # - rel_fields_hash => :fields hash either for a 'rel_team' context or a 'rel_swimmer' context;
    # - output_hash     => relay result Hash section, which should be the destination for the current data,
    #                      assumed to be already storing most of the zero-level fields like 'team' or 'timing'.
    # == Options:
    # - sum_overall_age => true if overall age should be summed up with the current relay swimmer age;
    #
    # == Returns:
    # the specified output_hash, updated with any relay swimmer data field found.
    #
    def process_relay_swimmer_fields(swimmer_idx, rel_fields_hash, output_hash, sum_overall_age: true)
      # Swimmer data source uses a non-indexed field or not?
      fld_swmmer = rel_fields_hash.key?('swimmer_name') ? 'swimmer_name' : "swimmer_name#{swimmer_idx}"
      fld_yob    = rel_fields_hash.key?('year_of_birth') ? 'year_of_birth' : "year_of_birth#{swimmer_idx}"
      fld_gender = rel_fields_hash.key?(GENDER_FIELD_NAME) ? GENDER_FIELD_NAME : "#{GENDER_FIELD_NAME}#{swimmer_idx}"

      # Extract field values:
      swimmer_name = rel_fields_hash[fld_swmmer]&.squeeze(' ')&.tr(',', ' ')
      # Bail out if we don't have at least a swimmer name to check for:
      return output_hash if swimmer_name.blank?

      team_name = output_hash['team'] # (ASSUMES: already set externally, before this call)
      year_of_birth = rel_fields_hash[fld_yob]
      gender_code   = rel_fields_hash[fld_gender]
      # DEBUG ----------------------------------------------------------------
      # binding.pry if year_of_birth.to_i.zero? && swimmer_name.starts_with?('*** ')
      # ----------------------------------------------------------------------

      swimmer_name, year_of_birth, gender_code = scan_results_or_search_db_for_missing_swimmer_fields(swimmer_name, year_of_birth, gender_code, team_name)
      # Bail out if the swimmer name was already processed:
      return output_hash if output_hash["swimmer#{swimmer_idx}"] == swimmer_name

      # Finally, (re-)assign field values:
      output_hash["swimmer#{swimmer_idx}"] = swimmer_name
      output_hash["#{GENDER_FIELD_NAME}#{swimmer_idx}"] = gender_code
      output_hash["year_of_birth#{swimmer_idx}"] = year_of_birth
      output_hash['overall_age'] += @season.begin_date.year - year_of_birth if sum_overall_age && year_of_birth.to_i.positive?

      # *** Check for same-depth case at rel_team-depth + 1: *all* relay swimmer fields (as sub-rows) inside a single'rel_swimmer' ***
      ((swimmer_idx + 1)..8).each do |idx|
        break unless rel_fields_hash.key?("swimmer_name#{idx}")

        # Extract swimmer name, year or gender at same depth (when available):
        process_relay_swimmer_fields(idx, rel_fields_hash, output_hash, sum_overall_age:)
      end

      output_hash
    end
    #-- -----------------------------------------------------------------------
    #++

    # Processes the <tt>relay_data_hash</tt> (assuming it's a valid Hash DAO yield by
    # the parsing of a relay result context), converting its data into the "flattened"
    # L2 hash standard format, ready to be converted to JSON as result section (for relay only).
    #
    # Updates in place both the <tt>resulting_sections</tt> and the <tt>parent_section</tt>.
    #
    # Returns the <tt>recompute_ranking</tt> flag and the latest current category & gender codes
    # found (or computed) for the <tt>parent_section</tt>, as a tuple.
    #
    # Doesn't do anything if the specified <tt>relay_data_hash</tt> doesn't have a recognized name
    # for any relay result context (in DAO Hash form).
    #
    # == Params:
    # - <tt>resulting_sections</tt> => the array of result sections already processed so far;
    # - <tt>parent_section</tt>     => the current output parent section (relay event with category) being processed;
    # - <tt>relay_data_hash</tt>    => the current input relay data Hash to be converted into the output hash format.
    #                                  needed to extract the output row result (may include category or header data itself).
    # == Returns:
    # The array having as items:
    #
    #    [<correct_parent_section>, <recompute_ranking>]
    #
    # - <tt>correct_parent_section</tt> => a new or existing PdfResults::L2EventSection instance reference.
    # - <tt>recompute_ranking</tt>      => +true+ if the section was changed and the category ranking value must be recomputed;
    #                                      +false+ otherwise.
    #
    # Returns [<parent_section>, false] in any other case.
    def translate_relay_data_hash(resulting_sections, parent_section, relay_data_hash)
      unless parent_section.is_a?(PdfResults::L2EventSection) && relay_data_hash.is_a?(Hash) && REL_RESULT_SECTION.include?(relay_data_hash[:name])
        return [parent_section, false]
      end

      # Supported hierarchies:
      #
      # PARENT: [event|category|rel_category]  (even incomplete or within absolute rankings)
      #     |
      #     +-- rel_team 🌀
      #         [:rows]
      #            +-- rel_swimmer 🌀
      #            +-- disqualified
      #
      rel_result_row = extract_relay_result_fields(relay_data_hash)
      # DEBUG ----------------------------------------------------------------
      # binding.pry if rel_result_row['disqualify_type'].to_s.start_with?('Arrivo irreg')
      # ----------------------------------------------------------------------
      $stdout.write("\033[1;33;38m.\033[0m") # orange # rubocop:disable Rails/Output
      # 1st completion try:
      updated_section, _recompute = point_to_parent_section_according_to_current_result_data_hash(resulting_sections, parent_section, relay_data_hash)
      # 2nd completion try:
      updated_section, _recompute = point_to_parent_section_according_to_current_result_data_hash(resulting_sections, updated_section, rel_result_row)

      # Skip adding rows to sections unless we have full section headers:
      return [parent_section, false] unless updated_section.complete?

      # Assuming the parent section already belongs to resulting_sections, this will find it using just its "keys":
      # (It will either re-use an existing one, or re-build it from scratch before adding it.)
      find_or_create_event_section_and_merge(resulting_sections, event_title: updated_section.event_title, category_code: updated_section.category_code,
                                                                 gender_code: updated_section.gender_code, result_row: rel_result_row)
      [parent_section, updated_section != parent_section]
    end
    #-- -----------------------------------------------------------------------
    #++

    # Processes the <tt>result_data_hash</tt> (assuming it's a valid Hash DAO yield by
    # the parsing of an *individual* result context), converting its data into the "flattened"
    # L2 hash standard format, ready to be converted to JSON as result section.
    #
    # Updates in place both the <tt>resulting_sections</tt> and the <tt>parent_section</tt>.
    #
    # Returns the <tt>recompute_ranking</tt> flag and the latest current category & gender codes
    # found (or computed) for the <tt>parent_section</tt>, as a tuple.
    #
    # Doesn't do anything if the specified <tt>result_data_hash</tt> doesn't have a recognized name
    # for any individual result context (in DAO Hash form).
    #
    # == Params:
    # - <tt>resulting_sections</tt> => the array of result sections already processed so far;
    # - <tt>parent_section</tt>     => the output parent section (individual event with category) being processed;
    # - <tt>result_data_hash</tt>   => the current individual result data Hash to be converted into the output hash format inside the parent_section.
    #                                  needed to extract the output row result (may include category or header data itself).
    # == Returns:
    # The array having as items:
    #
    #    [<correct_parent_section>, <recompute_ranking>]
    #
    # - <tt>correct_parent_section</tt> => a new or existing PdfResults::L2EventSection instance reference.
    # - <tt>recompute_ranking</tt>      => +true+ if the section was changed and the category ranking value must be recomputed;
    #                                      +false+ otherwise.
    #
    # Returns [<parent_section>, false] in any other case.
    def translate_ind_result_data_hash(resulting_sections, parent_section, result_data_hash)
      unless parent_section.is_a?(PdfResults::L2EventSection) && result_data_hash.is_a?(Hash) && IND_RESULT_SECTION.include?(result_data_hash[:name])
        return [parent_section, false]
      end

      # Supported hierarchies:
      #
      # PARENT: [event|category]  (even incomplete or within absolute rankings)
      #     |
      #     +---[results] 🌀
      #
      result_row = extract_indiv_result_fields(result_data_hash, parent_section.gender_code)
      # DEBUG ----------------------------------------------------------------
      # binding.pry if result_row['name'].to_s.start_with?('*** ')
      # ----------------------------------------------------------------------
      putc('.')

      # Example case: [event w/ gender only, no category]
      #                  --> [blank category]
      #                         --> [results w/ category code & gender inline x each row]

      # 1st completion try:
      updated_section, _recompute = point_to_parent_section_according_to_current_result_data_hash(resulting_sections, parent_section, result_data_hash)
      # 2nd completion try:
      updated_section, _recompute = point_to_parent_section_according_to_current_result_data_hash(resulting_sections, updated_section, result_row)

      # Skip adding rows to sections unless we have full section headers:
      return [parent_section, false] unless updated_section.complete?

      # Assuming the parent section already belongs to resulting_sections, this will find it using just its "keys":
      # (It will either re-use an existing one, or re-build it from scratch before adding it.)
      find_or_create_event_section_and_merge(resulting_sections, event_title: updated_section.event_title, category_code: updated_section.category_code,
                                                                 gender_code: updated_section.gender_code, result_row:)
      [parent_section, updated_section != parent_section]
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
