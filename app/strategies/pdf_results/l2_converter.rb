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
    CATEGORY_SECTION = %w[category rel_category].freeze

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
    def header
      {
        'layoutType' => 2,
        'name' => fetch_meeting_name,
        'meetingURL' => '',
        'manifestURL' => '',
        'dateDay1' => fetch_session_day,
        'dateMonth1' => fetch_session_month,
        'dateYear1' => fetch_session_year,
        'venue1' => '',
        'address1' => fetch_session_place,
        'poolLength' => fetch_pool_type.last
      }
    end

    # Returns the Array of Hash for the 'event' sections in standard "L2" structure.
    # Handles both individual & relays events (distinction comes also from category later
    # down on the hierarchy).
    def event_sections # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      resulting_sections = []

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

        # Sometimes the gender type may be found inside the EVENT title
        # (as in "4X50m Stile Libero Master Maschi"):
        event_title, event_length, _event_type_name, gender_code = fetch_event_title(event_hash)
        # Reset event related category (& gender, if available):
        curr_cat_code = fetch_rel_category_code(event_hash)
        curr_cat_gender = gender_code

        # --- IND.RESULTS (event -> results) ---
        section = {}
        if holds_category_type?(event_hash)
          section = ind_category_section(event_hash, event_title, curr_cat_code, curr_cat_gender)
          resulting_sections << section if section.present?
        end

        event_hash.fetch(:rows, [{}]).each do |row_hash| # rubocop:disable Metrics/BlockLength
          rows = []
          # --- RELAYS ---
          if /(4|6|8)x\d{2,3}/i.match?(event_length.to_s) && holds_relay_category_or_relay_result?(row_hash)
            # >>> Here: "row_hash" may be both 'category', 'rel_category', 'rel_team' or even 'event'
            # Safe to call even for non-'rel_category' hashes:
            section = rel_category_section(row_hash, event_title)
            # Category code or gender code wasn't found?
            # Try to get that from the current or previously category section found, if any:
            section['fin_sigla_categoria'] = curr_cat_code if section['fin_sigla_categoria'].blank? && curr_cat_code.to_s =~ /^\d+/
            section['fin_sesso'] = curr_cat_gender if section['fin_sesso'].blank? && curr_cat_gender.to_s.match?(/^[fmx]/i)

            # == Hard-wired "manual forward link" for relay categories only ==
            # Store current relay category & gender so that "unlinked" team relay
            # sections encountered later on get to be bound to the latest relay
            # fields found:
            # (this assumes the category section will be enlisted ALWAYS BEFORE actual the relay team result rows)
            if CATEGORY_SECTION.include?(row_hash[:name])
              # Don't overwrite category code & gender unless not set yet:
              curr_cat_code = section['fin_sigla_categoria'] if section['fin_sigla_categoria'].present?
              curr_cat_gender = section['fin_sesso'] if section['fin_sesso'].present?

              # SUPPORT for alternative-nested 'rel_team's (inside a dedicated category section -- example with 'rel_category'):
              # +-- event 🌀
              #     [:rows]
              #       +-- rel_category 🌀
              #            +-- rel_team 🌀
              #                [:rows]
              #                  +-- rel_swimmer 🌀
              #                  +-- disqualified
              # Loop on rel_team rows, when found, and build up the event rows with them
              row_hash[:rows].select { |row| REL_RESULT_SECTION.include?(row[:name]) }.each do |nested_row|
                rel_result_hash = rel_result_section(nested_row)
                rows << rel_result_hash
              end
              # Relay category code still missing? Fill-in possible missing category code (which is frequently missing in record trials):
              section = post_compute_rel_category_code(section, rows.last['overall_age']) if section['fin_sigla_categoria'].blank?

            # Process teams & relay swimmers/laps:
            elsif REL_RESULT_SECTION.include?(row_hash[:name])
              rel_result_hash = rel_result_section(row_hash)
              rows << rel_result_hash
              # Relay category code still missing? Fill-in possible missing category code (which is frequently missing in record trials):
              section = post_compute_rel_category_code(section, rel_result_hash['overall_age']) if section['fin_sigla_categoria'].blank?
            end

            # Set rows for current relay section:
            section['rows'] = rows
            resulting_sections << section if rows.present?

          # --- IND.RESULTS (category -> results) ---
          elsif holds_category_type?(row_hash)
            section = ind_category_section(row_hash, event_title, curr_cat_code, curr_cat_gender)
            row_hash.fetch(:rows, [{}]).each do |result_hash|
              # Ignore unsupported contexts:
              # NOTE: the name 'disqualified' will just signal the section start, but actual DSQ results
              # will be included into a 'result' section.
              next unless IND_RESULT_SECTION.include?(result_hash[:name])

              rows << ind_result_section(result_hash, section['fin_sesso'])
            end
            # Overwrite existing rows in current section:
            section['rows'] = rows
            resulting_sections << section if rows.present?

          # --- IND.RESULTS (event -> results) ---
          elsif holds_category_type?(event_hash) && IND_RESULT_SECTION.include?(row_hash[:name])
            # Since event holds the category, wrapper section should change only externally and we'll
            # add here only its rows:
            section['rows'] ||= []
            section['rows'] << ind_result_section(row_hash, section['fin_sesso'])

          # --- (Ignore unsupported contexts) ---
          else
            next
          end
        end
      end

      resulting_sections
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds up the category section that will hold the result rows.
    # (For individual results only.)
    # event_title, category_code & gender_code are used for default section values.
    def ind_category_section(category_hash, event_title, category_code, gender_code)
      {
        'title' => event_title,
        'fin_id_evento' => nil,
        'fin_codice_gara' => nil,
        'fin_sigla_categoria' => fetch_category_code(category_hash) || category_code,
        'fin_sesso' => fetch_category_gender(category_hash) || gender_code
      }
    end

    # Builds up the category section that will hold the result rows.
    # For relays only. Safe to call even if the category_hash isn't of
    # the "category" type: it will build just the event title instead.
    def rel_category_section(category_hash, event_title)
      {
        'title' => event_title,
        'fin_id_evento' => nil,
        'fin_codice_gara' => nil,
        'fin_sigla_categoria' => fetch_rel_category_code(category_hash),
        'fin_sesso' => fetch_rel_category_gender(category_hash)
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
      # DSQ label:
      dsq_label = extract_additional_dsq_labels(result_hash) if rank.to_i.zero?

      {
        'pos' => fields['rank']&.delete(')'),
        'name' => extract_nested_field_name(result_hash, SWIMMER_FIELD_NAMES),
        'year' => fields['year_of_birth'],
        'sex' => cat_gender_code,
        'badge_num' => fields['badge_num'],
        # Sometimes the 3-char region code may end up formatted in a second result row:
        # (TOS format: uses 2 different field names depending on position so the nil one doesn't overwrite the other)
        'badge_region' => fields['badge_region'] || fields['badge_region2'],
        'team' => extract_nested_field_name(result_hash, TEAM_FIELD_NAMES),
        'timing' => format_timing_value(fields['timing']),
        'score' => fields['std_score'],
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
      # DSQ label:
      dsq_label = extract_additional_dsq_labels(rel_team_hash) if rank.to_i.zero?

      row_hash = {
        'relay' => true,
        'pos' => rank,
        'team' => fields['team_name']&.squeeze(' '),
        'timing' => format_timing_value(fields['timing']),
        'score' => fields['std_score'],
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        # 'heat_rank' => fields['heat_rank'], # WIP: missing relay example w/ this
        'nation' => fields['nation'],
        'disqualify_type' => dsq_label # WIP: missing relay example w/ this
      }

      # Add lap & delta fields only when present in the source fields and resemble a timing value:
      (1..29).each do |idx|
        key = "lap#{idx * 50}"
        row_hash[key] = /\d{0,2}['\":.]?\d{2}[\":.]\d{2}/i.match?(fields[key]) ? fields[key] : nil
        key = "delta#{idx * 50}"
        row_hash[key] = /\d{0,2}['\":.]?\d{2}[\":.]\d{2}/i.match?(fields[key]) ? fields[key] : nil
      end

      # Add relay swimmer laps onto the same result hash & compute possible age group
      # in the meantime:
      overall_age = 0
      # *** Same-depth case 1 (GoSwim-type): relay swimmer at same level ***
      8.times do |idx|
        team_fields = rel_team_hash.fetch(:fields, {})
        next unless team_fields.key?("swimmer_name#{idx + 1}")

        # Extract swimmer name & year:
        row_hash["swimmer#{idx + 1}"] = team_fields["swimmer_name#{idx + 1}"]&.squeeze(' ')
        year_of_birth = team_fields["year_of_birth#{idx + 1}"].to_i
        row_hash["year_of_birth#{idx + 1}"] = year_of_birth
        overall_age = overall_age + @season.begin_date.year - year_of_birth if year_of_birth.positive?
      end

      rel_team_hash.fetch(:rows, [{}]).each_with_index do |rel_swimmer_hash, idx|
        # *** Nested case 1 (Ficr-type): relay swimmer sub-row ***
        if REL_SWIMMER_SECTION.include?(rel_swimmer_hash[:name])
          swimmer_fields = rel_swimmer_hash.fetch(:fields, {})
          row_hash["swimmer#{idx + 1}"] = swimmer_fields['swimmer_name']&.squeeze(' ')
          year_of_birth = swimmer_fields['year_of_birth'].to_i
          row_hash["year_of_birth#{idx + 1}"] = year_of_birth
          overall_age = overall_age + @season.begin_date.year - year_of_birth if year_of_birth.positive?

        # *** Nested case 2 (Ficr-type): DSQ label for relays ***
        # Support for 'disqualify_type' field as nested row:
        elsif rel_swimmer_hash[:name] == 'rel_dsq'
          # Precedence on swimmer DSQ labels over any pre-found:
          row_hash['disqualify_type'] = rel_swimmer_hash.fetch(:fields, {})['disqualify_type']
        end
      end
      row_hash['overall_age'] = overall_age

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
    def detect_header_fields
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
      field_hash = detect_header_fields
      return "#{field_hash['edition']}° #{field_hash['meeting_name']}" if field_hash['edition'].present?

      field_hash['meeting_name']
    end

    # Gets the Meeting session day number from the data Hash, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    def fetch_session_day
      field_hash = detect_header_fields
      field_hash.fetch('meeting_date', '').to_s.split(%r{[-/\s]}).first
    end

    # Gets the Meeting session month name from the data Hash, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    # Supports both numeric month & month names:
    #   "dd[-\s/]mm[-\s/]yy(yy)" or "dd[-\s/]MMM(mmm..)[-\s/]yy(yy)"
    def fetch_session_month
      field_hash = detect_header_fields
      month_token = field_hash.fetch('meeting_date', '').to_s
                              .match(%r{[/\-\s](\d{1,2}|\w+)[/\-\s]\d{2,4}}i)
                              &.captures&.first
      return Parser::SessionDate::MONTH_NAMES[month_token.to_i - 1] if /\d{2}/i.match?(month_token.to_s)

      month_token.to_s[0..2].downcase
    end

    # Gets the Meeting session year number, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    def fetch_session_year
      field_hash = detect_header_fields
      field_hash.fetch('meeting_date', '').to_s.split(%r{[-/\s]}).last
    end

    # Gets the Meeting session place, if available. Returns nil if not found.
    def fetch_session_place
      field_hash = detect_header_fields
      field_hash.fetch('meeting_place', '')
    end

    # Returns the pool total lanes (first) & the length in meters (last) as items
    # of an array of integers when the 'pool_type' field is found in the footer.
    # Returns an empty array ([]) otherwise.
    def fetch_pool_type
      # Retrieve pool_type from header when available & return:
      field_hash = detect_header_fields
      pool_type_len = field_hash.fetch('pool_type', '')
      return [nil, pool_type_len] if pool_type_len.present?

      # Fallback: search in footer, as in 1-ficr1

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
      gender = /mist/i.match?(gender.to_s) ? 'X' : gender.to_s.at(0)&.upcase
      ["#{length} #{type}", length, type, gender]
    end
    #-- -----------------------------------------------------------------------
    #++

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
        row_hash[:fields][CAT_FIELD_NAME].gsub(/Master\s/i, 'M')
                                         .gsub(/Under\s/i, 'U')
                                         .gsub(/Amatori\s/i, 'A')
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
        /(?>Under|Master)\s(?>Misti|Femmin\w*|Masch\w*)(?>\s(\d{2,3}\s-\s\d{2,3}))?/ui.match(key).captures.first.delete(' ')

      # Example key 2 => "{event_length: 'mistaffetta <4|6|8>x<len>'}|<style_name>|<mistaffetta|gender>|M(ASTER)?\s?<age1>-<age2>(|<base_time>)?"
      when /\|M(?>ASTER)?\s?(\d{2,3}-\d{2,3})/ui
        # Return a valid age-group code for relays ("<age1>-<age2>"):
        /\|M(?>ASTER)?\s?(\d{2,3}-\d{2,3})/ui.match(key).captures.first

      # Example key 3 => "M100-119|Masch|..."
      when /M(\d{2,3}-\d{2,3})\|(?>Masch|Femmin|Mist)/ui
        /M(\d{2,3}-\d{2,3})\|(?>Masch|Femmin|Mist)/ui.match(key).captures.first
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

      # *** Context 'rel_category' ***
      key = row_hash.fetch(:key, '')
      gender_name = case key
                    when /(?>Under|Master)\s(Misti|Femmin\w*|Masch\w*)\s(?>\d{2,3}\s-\s\d{2,3})/ui
                      # Example key 1 => "Master Misti 200 - 239"
                      /(?>Under|Master)\s(Misti|Femmin\w*|Masch\w*)\s(?>\d{2,3}\s-\s\d{2,3})/ui.match(key).captures.first

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
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------
      gender_name = row_hash[:fields][GENDER_FIELD_NAME] if gender_name.blank? && row_hash[:fields].key?(GENDER_FIELD_NAME)
      return GogglesDb::GenderType.intermixed.code if /mist/i.match?(gender_name.to_s)

      gender_name&.at(0)&.upcase
    end
    #-- -----------------------------------------------------------------------
    #++

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
          result[key] = format_timing_value(row_fields[key]) if row_fields.key?(key) && /\d{0,2}['\":.]?\d{2}[\":.]\d{2}/i.match?(row_fields[key])
          key = "delta#{idx * 50}"
          result[key] = format_timing_value(row_fields[key]) if row_fields.key?(key) && /\d{0,2}['\":.]?\d{2}[\":.]\d{2}/i.match?(row_fields[key])
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
      dsq_label = timing unless dsq_label.present? || timing.blank? || /\d{0,2}['\":.]?\d{2}[\":.]\d{2}/i.match?(timing)
      return if dsq_label.blank?

      # Make sure the timing field is cleared out when we have a DSQ label:
      result_hash[:fields]['timing'] = nil

      # Check for any possible additional (up to 3x rows) DSQ labels added as sibling rows:
      # add any additional DSQ label value (grep'ed as string keys) when present.
      additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == 'dsq_label' }
      dsq_label = "#{dsq_label}: #{additional_hash[:key]}" if additional_hash&.key?(:key)
      %w[x2 x3].each do |suffix|
        additional_hash = result_hash.fetch(:rows, [{}]).find { |h| h[:name] == "dsq_label_#{suffix}" }
        dsq_label = "#{dsq_label} #{additional_hash[:key]}" if additional_hash&.key?(:key)
      end
      dsq_label
    end
    #-- -----------------------------------------------------------------------
    #++

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

    # Returns the specified timing_string formatted in a more standardized format (<HH'MM"SS>).
    # Can detect and adjust:
    # - misc "TOS" formats (<HH.MM.SS>, <HH MM SS>)
    # - misc "EMI" formats (<HH:MM:SS>, <HH:MM.SS>)
    def format_timing_value(timing_string)
      # Assume first occurrence will be the minutes separator, the second will be the seconds'
      timing_string&.sub('.', '\'')&.sub('.', '"')
                   &.sub(' ', '\'')&.sub(' ', '"')
                   &.sub(':', '\'')&.sub(':', '"')
    end
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
