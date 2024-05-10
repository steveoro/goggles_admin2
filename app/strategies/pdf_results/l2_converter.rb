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
    # to be logically correct.
    #
    # Any result or lap can be split freely into multiple subsection or sub-rows and
    # each subsection/subrow name won't matter as all fields will be collected and become part
    # of a single parent hash.
    IND_RESULT_SECTION = %w[results results_alt].freeze

    # Supported "parent" section names for *relay results*. Same rules for IND_RESULT_SECTION apply.
    REL_RESULT_SECTION = %w[rel_team rel_team_alt].freeze

    # Supported section names for *relay swimmers*. Same rules for IND_RESULT_SECTION apply.
    REL_SWIMMER_SECTION = %w[rel_swimmer rel_swimmer_alt].freeze
    #-- -------------------------------------------------------------------------
    #++

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
        curr_rel_cat_code = nil
        curr_rel_cat_gender = gender_code
        event_hash.fetch(:rows, [{}]).each do |row_hash|
          section = {}
          rows = []
          # DEBUG ----------------------------------------------------------------
          # binding.pry if /mistaffetta 4x50/i.match?(event_title)
          # ----------------------------------------------------------------------

          # --- RELAYS ---
          if /(4|6|8)x\d{2,3}/i.match?(event_length.to_s) &&
             (row_hash[:name] == 'rel_category' || REL_RESULT_SECTION.include?(row_hash[:name]))
            # >>> Here: "row_hash" may be both 'rel_category' or 'rel_team'
            # Safe to call even for non-'rel_category' hashes:
            section = rel_category_section(row_hash, event_title)
            # DEBUG ----------------------------------------------------------------
            # binding.pry if event_title == "4X50 Misti - " && section['fin_sigla_categoria'].blank?
            # ----------------------------------------------------------------------

            # == Hard-wired "manual forward link" for relay categories only ==
            # Store current relay category & gender so that "unlinked" team relay
            # sections encountered later on get to be bound to the latest relay
            # fields found:
            # (this assumes 'rel_category' will be enlisted ALWAYS BEFORE actual the relay team result rows)
            if row_hash[:name] == 'rel_category'
              curr_rel_cat_code = section['fin_sigla_categoria'] if section['fin_sigla_categoria'].present?
              curr_rel_cat_gender = section['fin_sesso'] if section['fin_sesso'].present?

              # SUPPORT for alternative-nested 'rel_team's (inside 'rel_category'):
              # +-- event 🌀
              #     [:rows]
              #       +-- rel_category 🌀
              #            +-- rel_team 🌀
              #                [:rows]
              #                  +-- rel_swimmer 🌀
              #                  +-- disqualified
              # Loop on rel_team rows, when found, and build up the event rows with them
              row_hash[:rows].select { |row| row[:name] == 'rel_team' }.each do |nested_row|
                rel_result_hash = rel_result_section(nested_row)
                rows << rel_result_hash
              end

            # Process teams & relay swimmers/laps:
            elsif REL_RESULT_SECTION.include?(row_hash[:name])
              rel_result_hash = rel_result_section(row_hash)
              rows << rel_result_hash
              # Category code or gender code wasn't found?
              # Try to get that from the current or previously category section found, if any:
              section['fin_sigla_categoria'] = curr_rel_cat_code if section['fin_sigla_categoria'].blank? && curr_rel_cat_code.to_s =~ /^\d+/
              section['fin_sesso'] = curr_rel_cat_gender if section['fin_sesso'].blank? && curr_rel_cat_gender.to_s =~ /^[fmx]/i

              # Still missing? Fill-in possible missing category code (which is frequently missing in record trials):
              if section['fin_sigla_categoria'].blank?
                # Get the possible relay category code (excluding "absolutes": it's "gender split" as scope)
                # (if it has a gender split sub-category in it, it won't be "absolutes"/split-less)
                overall_age = rel_result_hash['overall_age']
                if overall_age.positive?
                  rel_cat_code = GogglesDb::CategoryType.relays.only_gender_split
                                                        .for_season(@season)
                                                        .where('(? >= age_begin) AND (? <= age_end)', overall_age, overall_age)
                                                        .last.code
                end
                section['fin_sigla_categoria'] = rel_cat_code if rel_cat_code.present?
                # Add category code to event title so that MacroSolver can deal with it automatically:
                section['title'] = "#{section['title']} - #{rel_cat_code}"
              end
            end

            # Set rows for current relay section:
            section['rows'] = rows

          # --- IND.RESULTS ---
          elsif row_hash[:name] == 'category'
            section = ind_category_section(row_hash, event_title)
            row_hash.fetch(:rows, [{}]).each do |result_hash|
              # Ignore unsupported contexts:
              # NOTE: the name 'disqualified' will just signal the section start, but actual DSQ results
              # will be included into a 'result' section.
              next unless IND_RESULT_SECTION.include?(result_hash[:name])

              rows << ind_result_section(result_hash, section['fin_sesso'])
            end
            # Overwrite existing rows in current section:
            section['rows'] = rows

          # --- (Ignore unsupported contexts) ---
          else
            next
          end

          resulting_sections << section if section.present? && section['rows'].present?
        end
      end

      resulting_sections
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds up the category section that will hold the result rows.
    # (For individual results only.)
    def ind_category_section(category_hash, event_title)
      {
        'title' => event_title,
        'fin_id_evento' => nil,
        'fin_codice_gara' => nil,
        'fin_sigla_categoria' => fetch_category_code(category_hash),
        'fin_sesso' => fetch_category_gender(category_hash)
      }
    end

    # Builds up the category section that will hold the result rows.
    # For relays only. Safe to call even if the category_hash isn't of
    # type 'rel_category': will build just the event title instead.
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
    # == Example *source* DAO Hash structure (from '1-ficr1'):
    # - 🌀: repeatable
    #
    # +-- event 🌀
    #     [:rows]
    #       +-- category 🌀
    #           [:rows]
    #             +-- results 🌀
    #             +-- disqualified
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
      row_hash = {
        'pos' => fields['rank'],
        'name' => fields['swimmer_name'],
        'year' => fields['year_of_birth'],
        'sex' => cat_gender_code,
        'team' => fields['team_name'],
        'timing' => fields['timing'],
        'score' => fields['std_score'],
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        'heat_rank' => fields['heat_rank'],
        'nation' => fields['nation'],
        'disqualify_type' => fields['disqualify_type']
      }

      # Add lap & delta fields only when present in the source result_hash:
      (1..29).each do |idx|
        key = "lap#{idx * 50}"
        row_hash[key] = fields[key] if fields[key].present?
        key = "delta#{idx * 50}"
        row_hash[key] = fields[key] if fields[key].present?
      end

      row_hash
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
    def rel_result_section(rel_team_hash) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return {} unless REL_RESULT_SECTION.include?(rel_team_hash[:name])

      fields = rel_team_hash.fetch(:fields, {})
      rank = fields['rank']
      # Support for 'disqualify_type' field at 'rel_team' field level:
      dsq_label = fields['disqualify_type'] if rank.to_i.zero?

      row_hash = {
        'relay' => true,
        'pos' => rank,
        'team' => fields['team_name'],
        'timing' => fields['timing'],
        'score' => fields['std_score'],
        # Optionals / added recently / To-be-supported by MacroSolver:
        'lane_num' => fields['lane_num'],
        # 'heat_rank' => fields['heat_rank'], # WIP: missing relay example w/ this
        'nation' => fields['nation'],
        'disqualify_type' => dsq_label # WIP: missing relay example w/ this
      }

      # Add lap & delta fields only when present in the source rel_team_hash:
      (1..29).each do |idx|
        key = "lap#{idx * 50}"
        row_hash[key] = fields[key] if fields[key].present?
        key = "delta#{idx * 50}"
        row_hash[key] = fields[key] if fields[key].present?
      end

      # Add relay swimmer laps onto the same result hash & compute possible age group
      # in the meantime:
      overall_age = 0
      rel_team_hash.fetch(:rows, [{}]).each_with_index do |rel_swimmer_hash, idx|
        if REL_SWIMMER_SECTION.include?(rel_swimmer_hash[:name])
          row_hash["swimmer#{idx + 1}"] = rel_swimmer_hash.fetch(:fields, {})['swimmer_name']
          year_of_birth = rel_swimmer_hash.fetch(:fields, {})['year_of_birth'].to_i
          row_hash["year_of_birth#{idx + 1}"] = year_of_birth
          overall_age = overall_age + Time.zone.now.year - year_of_birth if year_of_birth.positive?

        # Support for 'disqualify_type' field as nested row:
        elsif rel_swimmer_hash[:name] == 'rel_dsq'
          row_hash['disqualify_type'] = rel_swimmer_hash.fetch(:fields, {})['disqualify_type']
        end
      end
      row_hash['overall_age'] = overall_age

      row_hash
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

    # Example data header structure: (1-ficr)
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
    #         [{:name=>"results",
    #           :key=>"4|GINOTTI PINO|4|ITA|33.52|1:10.27|1:10.27|NUMA OSTILIO SPORTING CLUB|1968|36.75|863,81",
    #           :fields=>

    # Gets the Meeting name from the data Hash, if available; defaults to an empty string.
    def fetch_meeting_name
      "#{@data.fetch(:fields, {})['edition']}° #{@data.fetch(:fields, {})['meeting_name']}"
    end

    # Gets the Meeting session day number from the data Hash, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    def fetch_session_day
      @data.fetch(:fields, {})&.fetch('meeting_date', '').to_s.split(%r{[-/\s]}).first
    end

    # Gets the Meeting session month name from the data Hash, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    # Supports both numeric month & month names:
    #   "dd[-\s/]mm[-\s/]yy(yy)" or "dd[-\s/]MMM(mmm..)[-\s/]yy(yy)"
    def fetch_session_month
      month_token = @data.fetch(:fields, {})&.fetch('meeting_date', '').to_s.split(%r{[-/\s]}).second
      return Parser::SessionDate::MONTH_NAMES[month_token.to_i - 1] if /\d{2}/i.match?(month_token.to_s)

      month_token.to_s[0..2].downcase
    end

    # Gets the Meeting session year number, if available. Returns nil if not found.
    # Supports 3 possible separators for date tokens: "-", "/" or " ":
    def fetch_session_year
      @data.fetch(:fields, {})&.fetch('meeting_date', '').to_s.split(%r{[-/\s]}).last
    end

    # Gets the Meeting session place, if available. Returns nil if not found.
    def fetch_session_place
      @data.fetch(:fields, {})&.fetch('meeting_place', '')
    end

    # Returns the pool total lanes (first) & the length in meters (last) as items
    # of an array of integers when the 'pool_type' field is found in the footer.
    # Returns an empty array ([]) otherwise.
    def fetch_pool_type
      # Retrieve pool_type from header when available & return:
      pool_type_len = @data.fetch(:fields, {})&.fetch('pool_type', '')
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
      gender = event_hash.fetch(:fields, {})&.fetch('gender_type', '')
      # Return just the first gender code char:
      gender = /mist/i.match?(gender.to_s) ? 'X' : gender.to_s.first.upcase
      ["#{length} #{type}", length, type, gender]
    end

    # Gets the ind. result category code given its data hash.
    # Raises an error if the category hash is unsupported (always required for individ. results).
    def fetch_category_code(category_hash)
      raise 'Unsupported Category hash!' unless category_hash.is_a?(Hash) && category_hash[:name] == 'category'

      # *** Context 'category' ***
      key = category_hash.fetch(:key, '')

      # Example key 1 => "M55 Master Maschi 55 - 59"
      if /\s*([UAM]\d{2}(\sUnder|\sMaster)?\s(Femmine|Maschi))/ui.match?(key)
        key.split.first

      # Example key 2 => "<length>|<style>|<gender_label>|Master \d\d|<base_timing>|"
      elsif /\d{2,4}\|(?>stile(?>\slibero)?|dorso|rana|delfino|farfalla|misti)\|(maschil?.?|femminil?.?)\|(?>Master|Under)\s\d{2}\|/ui.match?(key)
        key.split('|')&.at(3)&.gsub(/Master /i, 'M')&.gsub(/Under /i, 'U')
      end
    end

    # Gets the relay result category code given its data hash.
    # Returns +nil+ for an unsupported category Hash or when the category code
    # is not found.
    def fetch_rel_category_code(category_hash)
      return unless category_hash.is_a?(Hash) && category_hash[:name] == 'rel_category'

      # *** Context 'rel_category' ***
      key = category_hash.fetch(:key, '')

      # Example key 1 => "Master Misti 200 - 239"
      if /\s?(master|under)\s*(maschi|femmine|misti)\s*/ui.match?(key)
        key.split(/\s?(master|under)\s?/i)&.last
           &.split(/\s?(maschi|femmine|misti)\s?/i)
           &.reject(&:blank?)
           &.last
           &.delete(' ')

      # Example key 2 => "{event_length: 'mistaffetta <4|6|8>x<len>'}|<style_name>|<mistaffetta|gender>|M<age1>-<age2>|<base_time>"
      elsif /\|M\d{2,3}-\d{2,3}\|/ui.match?(key)
        # Skip the first 'M' to get a valid code ("<age1>-<age2>")
        key.split('|')&.at(3)&.at(1..)
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Gets the individual category gender code as a single char, given its source data hash.
    # Raises an error if the category hash is unsupported (always required for individ. results).
    def fetch_category_gender(category_hash)
      raise 'Unsupported Category hash!' unless category_hash.is_a?(Hash) && category_hash[:name] == 'category'

      # *** Context 'category' ***
      key = category_hash.fetch(:key, '')
      # Example key 1 => "M55 Master Maschi 55 - 59"
      if /\s*([UAM]\d{2}(\sUnder|\sMaster)?\s(Femmine|Maschi))/ui.match?(key)
        key.split(/\s?(master|under)\s?/i)
           .last
           &.split(/\s/)&.first
           &.at(0)&.upcase

      # Example key 2 => "<length>|<style>|<gender_label>|Master \d\d|<base_timing>|"
      elsif /\d{2,4}\|(?>stile(?>\slibero)?|dorso|rana|delfino|farfalla|misti)\|(maschil?.?|femminil?.?)\|(?>Master|Under)\s\d{2}\|/ui.match?(key)
        key.split('|')&.at(2)&.at(0)&.upcase
      end
    end

    # Gets the relay category gender code as a single char, given its source data hash.
    # Returns +nil+ for an unsupported category Hash.
    def fetch_rel_category_gender(category_hash)
      return unless category_hash.is_a?(Hash) && category_hash[:name] == 'rel_category'

      # *** Context 'rel_category' ***
      key = category_hash.fetch(:key, '')
      gender_name = if /\s?(master|under)\s*(maschi|femmine|misti)\s*/ui.match?(key)
                      # Example key 1 => "Master Misti 200 - 239"
                      key.split(/\s?(master|under)\s?/i)
                         .last
                         &.split(/\s?(maschi|femmin|misti)\s?/i)
                         &.reject(&:blank?)
                         &.first

                    elsif /\|M\d{2,3}-\d{2,3}\|/ui.match?(key)
                      # Example key 2 => "{event_length: 'mistaffetta <4|6|8>x<len>'}|<style_name>|<mistaffetta|gender>|M<age1>-<age2>|<base_time>"
                      key.split('|')&.at(2)
                    end
      return GogglesDb::GenderType.intermixed.code if /mist/i.match?(gender_name.to_s)

      gender_name&.at(0)&.upcase
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
