# frozen_string_literal: true

module PdfResults
  # = PdfResults::L2Converter
  #
  #   - version:  7-0.7.10
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

    # Supported 'swimmer_name' column fields for individual results.
    SWIMMER_FIELD_NAMES = %w[swimmer_name swimmer_ext swimmer_suffix].freeze

    # Supported 'team_name' column fields for individual results.
    TEAM_FIELD_NAMES = %w[team_name team_ext team_suffix].freeze

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

    attr_reader :data

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
    #   > data = root_dao.data
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
      raise 'Invalid data_hash or season specified!' unless data_hash.is_a?(Hash) && data_hash[:name] == 'header' && season.is_a?(GogglesDb::Season)

      @data = data_hash
      @season = season
      # Collect the list of associated CategoryTypes to avoid hitting the DB for category code checking:
      @categories_cache = {}
      @season.category_types.each { |cat| @categories_cache[cat.code] = cat }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the Hash header in "L2" structure.
    # Seeks values both the 'header' and 'event' context data rows.
    def header
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
      session_day, session_month, session_year = Parser::SessionDate.from_eu_text(meeting_date_text) if meeting_date_text.present?

      {
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
      resulting_sections = []
      recompute_ranking = false

      # === Event loop: ===
      @data.fetch(:rows, [{}]).each_with_index do |event_hash, _idx| # rubocop:disable Metrics/BlockLength
        # Supported hierarchy for "event-type" depth level:
        #
        # [header]
        #     |
        #     +---[ranking_hdr|stats_hdr|event]
        #
        if event_hash[:name] == 'ranking_hdr'
          section = ranking_section(event_hash)
          resulting_sections << section if section.present?
        end
        if event_hash[:name] == 'stats_hdr'
          section = stats_section(event_hash)
          resulting_sections << section if section.present?
        end
        # Ignore other unsupported contexts at this depth level:
        next unless event_hash[:name] == 'event'

        # --- Extract all possible parent section fields from 'event' hash and use them in the loops below: ---

        # TODO:
        # If the event_hash has either one of 'meeting_date' and/or 'meeting_place', store
        # them into the header

        # Reset event-related category & gender when looping inside a new event context:
        section = {}
        curr_cat_code = nil

        # Sometimes the gender type may be found inside the EVENT title
        # (as in "4X50m Stile Libero Master Maschi" or "50 m Dorso Femmine"):
        event_title, event_length, _event_type_name, curr_cat_gender = fetch_event_title(event_hash)

        # --- RELAYS (event) ---
        if /(4|6|8)x\d{2,3}/i.match?(event_length.to_s) && holds_relay_category_or_relay_result?(event_hash)
          curr_cat_code = fetch_rel_category_code(event_hash)
          curr_cat_gender ||= fetch_rel_category_gender(event_hash)

        # --- IND.RESULTS (event) ---
        elsif holds_category_type?(event_hash)
          curr_cat_code = fetch_category_code(event_hash)
          curr_cat_gender ||= fetch_category_gender(event_hash)
        end

        # === Sub-event loop: ===
        event_hash.fetch(:rows, [{}]).each do |row_hash| # rubocop:disable Metrics/BlockLength
          # Supported hierarchy for "sub-event-type" depth level:
          #
          # [event]
          #     |
          #     +---[category|rel_category|results|rel_team]
          #
          rows = []
          # --- RELAYS (sub-event, both with or w/o categ.) ---
          if /(4|6|8)x\d{2,3}/i.match?(event_length.to_s) && holds_relay_category_or_relay_result?(row_hash)
            section = rel_category_section(row_hash, event_title, curr_cat_code, curr_cat_gender)

            # == Hard-wired "manual forward link" for relay categories only ==
            # Store current relay category & gender so that "unlinked" team relay
            # sections encountered later on, get to be bound to the latest relay fields found:
            # (this assumes the category section will be enlisted ALWAYS BEFORE actual the relay team result rows)
            if CATEGORY_SECTION.include?(row_hash[:name])
              # Don't overwrite category code & gender unless not set yet:
              curr_cat_code = section['fin_sigla_categoria'] if section['fin_sigla_categoria'].present?
              curr_cat_gender = section['fin_sesso'] if section['fin_sesso'].present?

              # Supported hierarchy (category -> rel_team):
              #
              # [category|rel_category]
              #     |
              #     +-- rel_team 🌀
              #         [:rows]
              #            +-- rel_swimmer 🌀
              #            +-- disqualified
              #
              # Loop on rel_team rows, when found, and build up the current sub-section rows with them:
              row_hash[:rows].select { |row| REL_RESULT_SECTION.include?(row[:name]) }.each do |nested_row|
                rel_result_hash = rel_result_section(nested_row)
                rows << rel_result_hash
              end

              # Relay category code still missing? Fill-in possible missing category code (which is frequently missing in record trials):
              if section['fin_sigla_categoria'].blank?
                section = post_compute_rel_category_code(section, rows.last['overall_age'])
                recompute_ranking = true
              end

            # Process teams & relay swimmers/laps:
            elsif REL_RESULT_SECTION.include?(row_hash[:name])
              # Supported hierarchy (event -> rel_team):
              #
              # [event]
              #     |
              #     +-- rel_team
              #
              rel_result_hash = rel_result_section(row_hash)
              rows << rel_result_hash
              # Relay category code still missing? Fill-in possible missing category code (which is frequently missing in record trials):
              if section['fin_sigla_categoria'].blank?
                section = post_compute_rel_category_code(section, rel_result_hash['overall_age'])
                recompute_ranking = true
              end
            end

            # Set rows for current relay section:
            section['rows'] = rows
            find_or_create_event_section_and_merge(resulting_sections, section) if section['rows'].present?

          # --- IND.RESULTS (category -> results: curr depth holds category data) ---
          elsif holds_category_type?(row_hash)
            # Supported hierarchy (extract both):
            #
            # [category]
            #     |
            #     +---[results]
            #
            section = ind_category_section(row_hash, event_title, curr_cat_code, curr_cat_gender)
            # Update current cat.code & gender pointers whenever the section gets overwritten:
            curr_cat_code = section['fin_sigla_categoria'] || curr_cat_code
            curr_cat_gender = section['fin_sesso'] || curr_cat_gender

            row_hash.fetch(:rows, [{}]).each do |result_hash|
              # Ignore unsupported contexts:
              # NOTE: the name 'disqualified' will just signal the section start, but actual DSQ results
              # will be included into a 'result' section.
              next unless IND_RESULT_SECTION.include?(result_hash[:name])

              rows << ind_result_section(result_hash, section['fin_sesso'])
            end
            # Overwrite existing rows in current section:
            section['rows'] = rows
            find_or_create_event_section_and_merge(resulting_sections, section) if section['rows'].present?

          # --- IND.RESULTS (event -> results: only parents holds possibly some category data) ---
          elsif holds_category_type?(event_hash) && IND_RESULT_SECTION.include?(row_hash[:name])
            # Supported hierarchy:
            #
            # [event] (with partial gender or category data)
            #     |
            #     +---[results]
            #
            section = ind_category_section(event_hash, event_title, nil, nil) # Don't use defaults unless we have full category data

            # Update current cat.code & gender pointers whenever the section gets overwritten:
            curr_cat_code = section['fin_sigla_categoria']
            curr_cat_gender = section['fin_sesso']
            result_row = ind_result_section(row_hash, curr_cat_gender)

            # Update gender from result row (should change with current row in individ. results
            # to reflect proper category/gender):
            section['fin_sesso'] = curr_cat_gender = result_row['sex']

            # Force category code post-computation only if not properly set:
            unless curr_cat_code.match?(/\d{2,3}/i)
              year_of_birth = result_row['year'].to_i
              section['fin_sigla_categoria'] = curr_cat_code = post_compute_ind_category_code(year_of_birth)
              # With category being manually computed, we need to recompute the rankings too:
              recompute_ranking = true
            end

            section['rows'] ||= []
            section['rows'] << result_row
            find_or_create_event_section_and_merge(resulting_sections, section) if section['rows'].present?

          # --- IND.RESULTS (event -> results, but NO category fields at all; i.e.: absolute rankings) ---
          elsif IND_RESULT_SECTION.include?(row_hash[:name])
            # Need to reconstruct both category & rankings:
            recompute_ranking = true
            result_row = ind_result_section(row_hash, curr_cat_gender)
            # Update gender from result row (should change with current row in individ. results
            # to reflect proper category/gender):
            section['fin_sesso'] = curr_cat_gender = result_row['sex']

            # Force category code post-computation only if not properly set:
            unless curr_cat_code.match?(/\d{2,3}/i)
              year_of_birth = result_row['year'].to_i
              section['fin_sigla_categoria'] = curr_cat_code = post_compute_ind_category_code(year_of_birth)
              # With category being manually computed, we need to recompute the rankings too:
              recompute_ranking = true
            end
            # DEBUG ----------------------------------------------------------------
            # TODO: WIP DEBUG!!
            binding.pry if curr_cat_code.blank?
            # ----------------------------------------------------------------------
            # THIS SHOULD NEVER OCCUR W/ CURR IMPL.:
            next if curr_cat_code.blank?

            # 2. Fetch or create proper event section with category:
            section = find_existing_event_section(resulting_sections, event_title, curr_cat_code, curr_cat_gender) ||
                      ind_category_section(row_hash, event_title, curr_cat_code, curr_cat_gender)
            # 3. Extract ind. result section and add it to the section's rows:
            section['rows'] ||= []
            section['rows'] << result_row
            find_or_create_event_section_and_merge(resulting_sections, section) if section['rows'].present?

          # --- (Ignore unsupported contexts) ---
          else
            next
          end
        end
      end

      recompute_ranking ? recompute_ranking_for_each_event_section(resulting_sections) : resulting_sections
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds up the category section that will hold the result rows.
    # (For individual results only.)
    # 'event_title', 'category_code' & 'gender_code' are used for default section values.
    def ind_category_section(category_hash, event_title, category_code, gender_code)
      {
        'title' => event_title,
        'fin_id_evento' => nil,
        'fin_codice_gara' => nil,
        'fin_sigla_categoria' => fetch_category_code(category_hash) || category_code,
        'fin_sesso' => fetch_category_gender(category_hash) || gender_code,
        # TODO: support this in MacroSolver:
        'base_time' => format_timing_value(category_hash.fetch(:fields, {})['base_time'])
      }
    end

    # Builds up the category section that will hold the result rows.
    # (For relays only.)
    # Safe to call even if the category_hash isn't of the "category" type: it will
    # build just the event title instead.
    # 'event_title', 'category_code' & 'gender_code' are used for default section values.
    def rel_category_section(category_hash, event_title, category_code, gender_code)
      # HERE: "row_hash" may be both 'category', 'rel_category', 'rel_team' or even 'event'
      # (Safe to be called even for non-'rel_category' hashes: "fetch_"-methods will return nil for no matches)
      {
        'title' => event_title,
        'fin_id_evento' => nil,
        'fin_codice_gara' => nil,
        'fin_sigla_categoria' => fetch_rel_category_code(category_hash) || category_code,
        'fin_sesso' => fetch_rel_category_gender(category_hash) || gender_code,
        # TODO: support this in MacroSolver:
        'base_time' => format_timing_value(category_hash.fetch(:fields, {})['base_time'])
      }
    end

    # Builds up the "event" section that will hold the overall team ranking rows (when present).
    def ranking_section(event_hash)
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
          'ind_score' => ranking_hash.fetch(:fields, {})['ind_score'],
          'overall_score' => ranking_hash.fetch(:fields, {})['overall_score']
        }
      end

      section
    end

    # Builds up the "stats" section that will hold the overall statistics rows for
    # the whole Meeting (when present).
    def stats_section(event_hash)
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
    # - swimmer_name  => complete name of the swimmer;
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
      if year_of_birth.to_i.zero? || gender_code.blank?
        scanned_year_of_birth, scanned_gender_code = search_result_row_with_swimmer(swimmer_name, team_name)
        year_of_birth ||= scanned_year_of_birth if scanned_year_of_birth.present?
        gender_code ||= scanned_gender_code if scanned_gender_code.present?
      end
      year_of_birth = adjust_2digit_year(year_of_birth) # (no-op if the year is already 4-digits)

      # Whenever the gender is still unknown, use the DB finders as second-last resort:
      if gender_code.blank?
        cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Swimmer, complete_name: swimmer_name, year_of_birth:)
        if cmd.successful?
          gender_code = cmd.result.male? ? 'M' : 'F'
          year_of_birth = cmd.result.year_of_birth
          swimmer_name = cmd.result.complete_name
        else
          # As a very last resort, make an educated guess for the gender from the name, using common locale-IT exceptions:
          gender_code = if swimmer_name.match?(/\w+[nosl\-]\s?maria|andrea?$|one$|gabriele|gioele|luca|\w+[gkcnos]'?$/ui)
                          'M'
                        else
                          'F'
                        end
        end
      end

      [swimmer_name, year_of_birth, gender_code]
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
    def ind_result_section(result_hash, cat_gender_code)
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
      rank = fields['rank']
      year_of_birth = fetch_field_with_alt_value(fields, 'year_of_birth')
      swimmer_name = extract_nested_field_name(result_hash, SWIMMER_FIELD_NAMES)
      team_name = extract_nested_field_name(result_hash, TEAM_FIELD_NAMES)
      # DSQ label:
      dsq_label = extract_additional_dsq_labels(result_hash) if rank.to_i.zero?

      # Don't even consider 'X' as a possible default gender, since we're dealing with swimmers
      # and not with categories of events:
      cat_gender_code = nil unless cat_gender_code.upcase == 'F' || cat_gender_code.upcase == 'M'
      swimmer_name, year_of_birth, gender_code = scan_results_or_search_db_for_missing_swimmer_fields(swimmer_name, year_of_birth, cat_gender_code, team_name)

      {
        'pos' => fields['rank']&.delete(')'),
        'name' => swimmer_name,
        'year' => year_of_birth,
        'sex' => gender_code,
        # TODO: support this in MacroSolver:
        'badge_num' => fetch_field_with_alt_value(fields, 'badge_num'),
        # Sometimes the 3-char region code may end up formatted in a second result row:
        # (TOS format: uses 2 different field names depending on position so the nil one doesn't overwrite the other)
        'badge_region' => fetch_field_with_alt_value(fields, 'badge_region'),
        'team' => team_name,
        'timing' => format_timing_value(fetch_field_with_alt_value(fields, 'timing')),
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
    def rel_result_section(rel_team_hash) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
      return {} unless REL_RESULT_SECTION.include?(rel_team_hash[:name])

      fields = rel_team_hash.fetch(:fields, {})
      rank = fields['rank']&.delete(')')
      timing = format_timing_value(fetch_field_with_alt_value(fields, 'timing'))
      # Additional DSQ label ('dsq_label' field inside nested row):
      dsq_label = extract_additional_dsq_labels(rel_team_hash) if rank.to_i.zero? || timing.blank?

      row_hash = {
        'relay' => true,
        'pos' => rank,
        'team' => extract_nested_field_name(rel_team_hash, TEAM_FIELD_NAMES),
        'timing' => timing,
        'score' => fetch_field_with_alt_value(fields, 'std_score'),
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        'nation' => fields['nation'],
        'disqualify_type' => dsq_label # WIP: missing relay example w/ this
      }

      # Add lap & delta fields only when present in the source fields and resemble a timing value:
      (1..29).each do |idx|
        key = "lap#{idx * 50}"
        value = fetch_field_with_alt_value(fields, key)
        row_hash[key] = format_timing_value(value) if /\d{0,2}['\"\s:.]?\d{2}[\"\s:.]\d{2}/i.match?(value)

        key = "delta#{idx * 50}"
        value = fetch_field_with_alt_value(fields, key)
        row_hash[key] = format_timing_value(value) if /\d{0,2}['\"\s:.]?\d{2}[\"\s:.]\d{2}/i.match?(value)
      end

      # Add relay swimmer laps onto the same result hash & compute possible age group
      # in the meantime:
      row_hash['overall_age'] = 0
      # *** Same-depth case 1 (GoSwim-type): relay swimmer fields inside 'rel_team' ***
      8.times do |idx|
        team_fields = rel_team_hash.fetch(:fields, {})
        next unless team_fields.key?("swimmer_name#{idx + 1}")

        # Extract swimmer name, year or gender (when available):
        process_relay_swimmer_fields(idx + 1, team_fields, row_hash, nested: false)
      end

      rel_team_hash.fetch(:rows, [{}]).each_with_index do |rel_swimmer_hash, idx|
        # *** Nested case 1 (Ficr-type): 'rel_team' -> 'rel_swimmer' sub-row ***
        if REL_SWIMMER_SECTION.include?(rel_swimmer_hash[:name])
          swimmer_fields = rel_swimmer_hash.fetch(:fields, {})
          # Extract swimmer name, year or gender (when available):
          process_relay_swimmer_fields(idx + 1, swimmer_fields, row_hash, nested: true)

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
      footer = @data.fetch(:rows, [{}])&.first&.[](:rows)&.find { |h| h[:name] == 'footer' }

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
      /mist|maschi\se\sfemmine/i.match?(gender_text.to_s)
    end

    # Returns +true+ only if the supplied row_hash seems to support and
    # store a string value representing a possible CategoryType code only for individual results.
    def holds_category_type?(row_hash)
      row_hash.is_a?(Hash) &&
        ((row_hash[:name] == 'category') ||
         (row_hash.fetch(:fields, {}).key?(CAT_FIELD_NAME) &&
          !row_hash.fetch(:fields, {})['event_length'].to_s.match?(/X/i)))
    end

    # Gets the ind. result category code directly from the given data hash key or the supported
    # field name if anything else fails.
    # Estracting the code from the key value here is more generic than relying on
    # the actual field names. Returns +nil+ for any other unsupported case.
    def fetch_category_code(row_hash)
      # *** Context 'category'|'event' ***
      # (Assumed to include the "category title" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '')

      # key type 1, example: [...]"M55 Master Maschi 55 - 59"[...]
      if /\s*([UAM]\d{2})(?>\sUnder|\sMaster)?\s(?>Femmine|Maschi)/ui.match?(key)
        /\s*([UAM]\d{2})(?>\sUnder|\sMaster)?\s(?>Femmine|Maschi)/ui.match(key).captures.first

      # key type 1, example: "...|(Master \d\d)|..."
      elsif /\|((?>Master|Under|Amatori)\s\d{2})\|/ui.match?(key)
        /\|((?>Master|Under|Amatori)\s\d{2})\|/ui.match(key).captures
                                                 .first
                                                 .gsub(/Master\s/i, 'M')
                                                 .gsub(/Under\s/i, 'U')
                                                 .gsub(/Amatori\s/i, 'A')

      # use just the field value "as is":
      elsif row_hash[:fields].key?(CAT_FIELD_NAME)
        row_hash[:fields][CAT_FIELD_NAME].gsub(/Master\s?/i, 'M')
                                         .gsub(/Under\s?/i, 'U')
                                         .gsub(/Amatori\s?/i, 'A')
                                         .gsub(/\s/i, '')
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
    # Returns +nil+ for any other unsupported case.
    def fetch_rel_category_code(row_hash)
      # *** Context 'rel_category' ***
      # (Assumed to include the "category title" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '')

      # Example key 1 => "Master Misti 200 - 239"
      case key
      when /(?>Under|Master)\s(?>Misti|Femmin\w*|Masch\w*)(?>\s(\d{2,3}\s-\s\d{2,3}))?/ui
        /(?>Under|Master)\s(?>Misti|Femmin\w*|Masch\w*)(?>\s(\d{2,3}\s-\s\d{2,3}))?/ui.match(key).captures&.first&.delete(' ')

      # Example key 2 => "{event_length: 'mistaffetta <4|6|8>x<len>'}|<style_name>|<mistaffetta|gender>|M(ASTER)?\s?<age1>-<age2>(|<base_time>)?"
      when /\|M(?>ASTER)?\s?(\d{2,3}-\d{2,3})/ui
        # Return a valid age-group code for relays ("<age1>-<age2>"):
        /\|M(?>ASTER)?\s?(\d{2,3}-\d{2,3})/ui.match(key).captures&.first

      # Example key 3 => "M100-119|Masch|..."
      when /M(\d{2,3}-\d{2,3})\|(?>Masch|Femmin|Mist)/ui
        /M(\d{2,3}-\d{2,3})\|(?>Masch|Femmin|Mist)/ui.match(key).captures&.first
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Gets the individual category gender code as a single char, given its source data hash.
    # Raises an error if the category hash is unsupported (always required for individ. results).
    def fetch_category_gender(row_hash)
      # *** Context 'category'|'event' ***
      # (Assumed to include the "gender type label" field, among other possible fields in the key)
      key = row_hash.fetch(:key, '')

      # key type 1, example: [...]"M55 Master Maschi 55 - 59"[...]
      if /\s*[UAM]\d{2}(?>\sUnder|\sMaster)?\s(Femmine|Maschi)/ui.match?(key)
        /\s*[UAM]\d{2}(?>\sUnder|\sMaster)?\s(Femmine|Maschi)/ui.match(key).captures.first.upcase.at(0)

      # key type 2, example: "...|(masch\w+|femmin\w+)\|..." (more generic)
      elsif /\|(masch\w*|femmin\w*)\|/ui.match?(key)
        /\|(masch\w*|femmin\w*)\|/ui.match(key).captures.first.upcase.at(0)

      # use just the first capital character from the field value:
      elsif row_hash[:fields].key?(GENDER_FIELD_NAME)
        row_hash[:fields][GENDER_FIELD_NAME]&.upcase&.at(0)
      end
    end

    # Gets the relay category gender code as a single char, given its source data hash.
    # Returns +nil+ for an unsupported category Hash.
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
      gender_name = row_hash[:fields][GENDER_FIELD_NAME] if gender_name.blank? && row_hash[:fields].key?(GENDER_FIELD_NAME)
      return GogglesDb::GenderType.intermixed.code if intermixed_gender_label?(gender_name)

      gender_name&.at(0)&.upcase
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
    # Returns an empty string when no values or valid field names are found (even at the "root" level
    # of the result_hash).
    def extract_nested_field_name(result_hash, supported_field_names)
      result_value = ''
      result_hash.fetch(:fields, {}).each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if supported_field_names.include?(fname) }

      # Check for any possible additional (& supported) fields that need to be collated into
      # a single swimmer name, which could be possibly stored inside sibling rows:
      result_hash.fetch(:rows, [{}]).each do |row_hash|
        next if row_hash[:fields].blank?

        row_hash[:fields].each { |fname, fvalue| result_value += " #{fvalue&.squeeze(' ')}" if supported_field_names.include?(fname) }
      end
      result_value.strip
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
        (1..29).each do |idx|
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
    # if there are any sibling DAO rows named 'dsq_label', 'dsq_label_x2' or 'dsq_label_x3';
    # +nil+ otherwise.
    #
    # == Notes:
    # 1. expected field name    => 'disqualify_type'
    # 2. sub-row contexts names => 'dsq_label' or 'dsq_label_XXX'
    #
    def extract_additional_dsq_labels(result_hash)
      dsq_label = result_hash.fetch(:fields, {})['disqualify_type']
      timing = result_hash.fetch(:fields, {})['timing']
      # Check for any possible additional (up to 3x rows) DSQ labels added as sibling rows:
      # add any additional DSQ label value (grep'ed as string keys) when present.
      additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == 'dsq_label' }
      dsq_label = [dsq_label, additional_hash[:key]].compact.join(': ') if additional_hash&.key?(:key)
      %w[x2 x3].each do |suffix|
        additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == "dsq_label_#{suffix}" }
        dsq_label = [dsq_label, additional_hash[:key]].compact.join(' ') if additional_hash&.key?(:key)
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

    # Seeks any existing event section given its title, category string and gender string codes.
    # Returns +nil+ when not found.
    # == Params:
    # - array_of_sections: the Array of event section Hash yield by the conversion loop;
    #   typically, in L2 format, this is an event section holding several rows for results
    #   (either individual or relays)
    #
    # - title: string title of the section
    # - category_code: string category code used for the 'fin_sigla_categoria' field of the section
    # - gender_code: string gender code used for the 'fin_sesso' field of the section
    def find_existing_event_section(array_of_sections, title, category_code, gender_code)
      return unless array_of_sections.present? && array_of_sections.is_a?(Array) && title.present? &&
                    category_code.present? && gender_code.present?

      array_of_sections.find do |section_hash|
        section_hash['title'] == title && section_hash['fin_sigla_categoria'] == category_code &&
          section_hash['fin_sesso'] == gender_code
      end
    end

    # Scans the +array_of_sections+ adding +section+ to this master array only when missing.
    #
    # If the section is already found and the source section_hash has already sibling rows,
    # the 'rows' subarray is merged into the existing event section.
    #
    # "Merging" implies scanning each source row, comparing it with any of the existing
    # destination 'rows' subarray, and copying the source row (from section_hash) into the
    # destination array (existing section 'rows') only if there are differences between the two.
    #
    # === Note:
    # 1. Prevents duplicates in array due to careless usage of '<<'.
    # 2. Since objects like an Hash are referenced in an array, updating directly the object instance
    #    or a reference to it will make the referenced link inside the array be up to date as well.
    #
    # == Params:
    # - array_of_sections: the Array of event section Hash yield by the conversion loop;
    #   typically, in L2 format, this is an event section holding several rows for results
    #   (either individual or relays)
    # - section_hash: an "event section" Hash (it should have at least a 'title', a 'fin_sigla_categoria'
    #   and 'fin_sesso' keys in it).
    #
    # == Returns:
    # +nil+ on no-op, the updated array_of_sections otherwise.
    #
    def find_or_create_event_section_and_merge(array_of_sections, section_hash)
      return if !array_of_sections.is_a?(Array) || !section_hash.is_a?(Hash) ||
                !section_hash.key?('title') || !section_hash.key?('fin_sigla_categoria') ||
                !section_hash.key?('fin_sesso')

      # Fetch proper event section with category:
      event_section = find_existing_event_section(array_of_sections, section_hash['title'], section_hash['fin_sigla_categoria'], section_hash['fin_sesso'])

      # Add/MERGE rows from section_hash when a matching event section is found:
      if event_section.present? && section_hash['rows'].present?
        event_section['rows'] ||= []
        # Scan source 'rows' from section_hash, if any:
        section_hash['rows'].each do |result_row|
          # Foreach source row, add it to the existing event section rows only when different or new
          # (compare all source fields vs dest fields in all rows)
          event_section['rows'] << result_row if event_section['rows'].none?(result_row)
        end
      else
        array_of_sections << section_hash
      end
    end

    # Sorts each +array_of_sections+ rows array by timing recomputing also the rank value.
    # (Useful for results in event sections with an absolute ranking and without category split.)
    #
    # == Params:
    # - array_of_sections: the Array of event section Hash yield by the conversion loop;
    #   typically, in L2 format, this is an event section holding several rows for results
    #   (either individual or relays)
    #
    # == Returns:
    # The updated array of sections (in any case).
    #
    def recompute_ranking_for_each_event_section(array_of_sections)
      return array_of_sections unless array_of_sections.is_a?(Array)

      array_of_sections.each do |event_section|
        next unless event_section.is_a?(Hash)

        # 1. Sort event rows by timing
        event_section.fetch('rows', []).sort! do |row_a, row_b|
          val_1 = Parser::Timing.from_l2_result(row_a['timing']) || Parser::Timing.from_l2_result("99'99\"00")
          val_2 = Parser::Timing.from_l2_result(row_b['timing']) || Parser::Timing.from_l2_result("99'99\"00")
          val_1 <=> val_2
        end
        # 2. Recompute ranking:
        event_section.fetch('rows', []).each_with_index do |row_hash, index|
          row_hash['pos'] = row_hash['timing'].present? ? index + 1 : nil
        end
      end

      array_of_sections
    end

    # Detects the possible valid individual result category code given the year_of_birth of the swimmer.
    # Returns the string category code ("M<nn>") or +nil+ when not found.
    # == Params:
    # - year_of_birth: year_of_birth of the swimmer as integer
    def post_compute_ind_category_code(year_of_birth)
      return unless year_of_birth.positive?

      age = @season.begin_date.year - year_of_birth
      curr_cat_code, _cat = @categories_cache.find { |_c, cat| !cat.relay? && (cat.age_begin..cat.age_end).cover?(age) && !cat.undivided? }
      curr_cat_code
    end

    # Detects the possible valid relay category code given the overall age of the involved swimmers.
    # This helper updates the section hash directly. Returns the section itself.
    # == Params:
    # - section: current section hash
    # - overall_age: integer overall age of all relay swimmers
    def post_compute_rel_category_code(section, overall_age)
      return section unless overall_age.positive? && section.is_a?(Hash)

      curr_cat_code, _cat = @categories_cache.find { |_c, cat| cat.relay? && (cat.age_begin..cat.age_end).cover?(overall_age) && !cat.undivided? }
      section['fin_sigla_categoria'] = curr_cat_code if curr_cat_code.present?
      # Add category code to event title so that MacroSolver can deal with it automatically:
      section['title'] = "#{section['title']} - #{curr_cat_code}"
      section
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the specified timing_string formatted in a more standardized format (<MM'SS"HN>).
    # Can detect and adjust:
    # - misc "TOS" formats (<MM.SS.HN>, <MM SS HN>, <SS,HN>)
    # - misc "EMI" formats (<MM:SS:HN>, <MM:SS.HN>)
    def format_timing_value(timing_string)
      # Assume first occurrence will be the minutes separator, the second will be the seconds' (from the hundredths)
      timing_string&.sub('.', '\'')&.sub('.', '"')
                   &.sub(' ', '\'')&.sub(' ', '"')
                   &.sub(':', '\'')&.sub(':', '"')
                   &.sub(',', '"')
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
      @data.fetch(:rows, [{}]).each do |event_hash|
        # Ignore other unsupported contexts at this depth level:
        next unless event_hash[:name] == 'event'

        # Set current searched gender from event when found
        _title, _length, _type, curr_gender_from_event = fetch_event_title(event_hash)
        # Don't even consider 'X' as a gender, since we're dealing with swimmers & not categories of events:
        curr_gender_from_event = nil unless curr_gender_from_event.upcase == 'F' || curr_gender_from_event.upcase == 'M'

        event_hash.fetch(:rows, [{}]).each do |category_hash|
          # Set current searched gender from category when found
          curr_gender = fetch_category_gender(category_hash) || curr_gender_from_event
          # Return after first match
          result = category_hash.fetch(:rows, [{}])
                                .find do |row|
                                  fields = row.fetch(:fields, {})
                                  fields['swimmer_name']&.upcase == swimmer_name&.upcase &&
                                    fields['team_name']&.upcase == team_name&.upcase
                                end

          return [result.fetch(:fields, {})['year_of_birth'].to_i, curr_gender] if result.present?
        end
      end

      nil
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts the relay swimmer data fields into the "flattened" L2 hash format,
    # ready to be converted to JSON as result section.
    #
    # == Params:
    # - swimmer_idx     => current relay swimmer index; 0 for dedicated 'rel_swimmer' contexts,
    #                      a positive number for swimmer data stored at the same depth level as the team;
    # - rel_fields_hash => :fields hash either for a 'rel_team' context or a 'rel_swimmer' context;
    # - output_hash     => relay result Hash section, which should be the destination for the current data,
    #                      assumed to be already storing most of the zero-level fields like 'team' or 'timing'.
    # == Returns:
    # the specified output_hash, updated with any relay swimmer data field found.
    #
    def process_relay_swimmer_fields(swimmer_idx, rel_fields_hash, output_hash, nested: true)
      # TODO: Add proper support in MacroSolver for 'swimmer_lap<N>' &  'swimmer_delta<N>' fields,
      #       in nested or unested swimmer data sources (either indexed inside 'rel_team' or non-indexed
      #       inside nested 'rel_swimmer'-type Hashes) that store the delta/lap timings for the corrispondent
      #       relay_swimmer fraction in index.
      #       (It needs the event length or the lap length to be fully processable, otherwise
      #       an educated guess for the lap length is needed.)

      # Swimmer data source at a nested depth level with non-indexed fields (or not, for same depth level)?
      fld_swmmer = nested ? 'swimmer_name' : "swimmer_name#{swimmer_idx}"
      fld_yob    = nested ? 'year_of_birth' : "year_of_birth#{swimmer_idx}"
      fld_gender = nested ? GENDER_FIELD_NAME : "#{GENDER_FIELD_NAME}#{swimmer_idx}"
      fld_lap    = nested ? 'swimmer_lap' : "swimmer_lap#{swimmer_idx}"
      fld_delta  = nested ? 'swimmer_delta' : "swimmer_delta#{swimmer_idx}"

      # Extract field values:
      team_name = output_hash['team'] # (ASSUMES: already set externally, before this call)
      swimmer_name  = rel_fields_hash[fld_swmmer]&.squeeze(' ')&.tr(',', ' ')
      year_of_birth = rel_fields_hash[fld_yob].to_i
      gender_code   = rel_fields_hash[fld_gender] # To-be-supported by MacroSolver
      lap_timing    = rel_fields_hash[fld_lap]    # To-be-supported by MacroSolver
      delta_timing  = rel_fields_hash[fld_delta]  # To-be-supported by MacroSolver

      swimmer_name, year_of_birth, gender_code = scan_results_or_search_db_for_missing_swimmer_fields(swimmer_name, year_of_birth, gender_code, team_name)

      # Finally, (re-)assign field values:
      output_hash["swimmer#{swimmer_idx}"] = swimmer_name
      output_hash["#{GENDER_FIELD_NAME}#{swimmer_idx}"] = gender_code
      output_hash["year_of_birth#{swimmer_idx}"] = year_of_birth
      output_hash['overall_age'] += @season.begin_date.year - year_of_birth if year_of_birth.to_i.positive?
      output_hash["swimmer_lap#{swimmer_idx}"] = lap_timing
      output_hash["swimmer_delta#{swimmer_idx}"] = delta_timing
      output_hash
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
