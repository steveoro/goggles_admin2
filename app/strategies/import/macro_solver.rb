# frozen_string_literal: true

module Import
  #
  # = MacroSolver
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241017
  #
  # Scans the already-parsed Meeting results JSON object (which stores a whole set of results)
  # and finds existing & corresponding entity rows or creates (locally) any missing associated
  # entities, so that all or most of its bindings can be considered as "solved" in a single pass.
  #
  # The goal is to obtain a single SQL transaction for each Meeting with its related results (@see MacroCommitter),
  # although multiple transactions for the same Meeting are supported (so that additional
  # results can be added or updated in multiple runs).
  #
  # For the supported Hash formats (depending on the layout type of the crawled result page),
  # see crawler/server/results-crawler.js.
  #
  # == Note
  # The premise for having an actual SQL batch file that can be executed remotely is to have the localhost database
  # replica perfectly cloned from the remote one. (THE 2 DBs MUST BE IN SYNC!)
  #
  # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
  class MacroSolver
    MAX_SWIMMERS_X_RELAY = 8 # Considering only this max number of relay swimmers foreach row

    # Creates a new MacroSolver instance.
    #
    # == Params
    # - <tt>:season_id</tt> => GogglesDb::Season#id associated with the JSON result file (*required*)
    # - <tt>:data_hash</tt> => the Hash from the parsed JSON result file (*required*)
    # - <tt>:toggle_debug</tt> => when true, additional debug output will be generated (default: +false+)
    #                             set it to 2 to output the DB search commands output to STDOUT
    #
    def initialize(season_id:, data_hash:, toggle_debug: false)
      raise(ArgumentError, 'Invalid season_id') unless GogglesDb::Season.exists?(season_id)
      raise(ArgumentError, 'Invalid or unknown data_hash type') unless data_hash.is_a?(Hash) && data_hash.key?('layoutType')

      @season = GogglesDb::Season.find(season_id)
      # Collect the list of associated CategoryTypes to avoid hitting the DB on each section:
      @categories_cache = {}
      @season.category_types.each { |cat| @categories_cache[cat.code] = cat }
      @data = data_hash || {}
      @toggle_debug = toggle_debug
      @retry_needed = @data['sections']&.any? { |sect| sect['retry'].present? }
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>model_name</tt> class constant.
    # (Uses as implied default namespace <tt>"GogglesDb::"</tt>.)
    #
    # == Params:
    # - <tt>model_name</tt>: the string name of the model, with the implied GogglesDb namespace
    #
    def self.model_class_for(model_name)
      "GogglesDb::#{model_name.to_s.camelcase}".constantize
    end

    # Returns the array of attribute (column) string names for the specified <tt>model_name</tt>,
    # without any namespace.
    # (Uses as implied default namespace <tt>"GogglesDb::"</tt>.)
    #
    # == Params:
    # - <tt>model_name</tt>: the string name of the model, with the implied GogglesDb namespace
    #
    def self.model_attribute_names_for(model_name)
      "GogglesDb::#{model_name.to_s.camelcase}".constantize.new.attributes.keys
    end

    # Returns a copy of the list of attributes/columns as an Hash using the specified Model name
    # as source of truth for which the attributes should be kept in the list.
    # Everything that's not an actual column of the table will be stripped of the list while
    # the original unfiltered hash remains unmodified.
    #
    # == Params:
    # - <tt>unfiltered_hash</tt>: unfiltered Hash of attributes
    # - <tt>model_name</tt>: the string name of the model, with the implied GogglesDb namespace
    #
    # == Returns:
    # the Hash of attributes (column names => values) extracted from <tt>unfiltered_hash</tt> and
    # valid for updating or creating an instance of <tt>model_name</tt>.
    # Returns an empty Hash otherwise.
    #
    def self.actual_attributes_for(unfiltered_hash, model_name)
      return {} unless unfiltered_hash.respond_to?(:reject)

      valid_column_keys = model_attribute_names_for(model_name)
      unfiltered_hash.select { |key, _v| valid_column_keys.include?(key) }
    end
    #-- -------------------------------------------------------------------------
    #++

    # 1-pass solver wrapping the steps (meeting & sessions; teams & swimmers; events, results & rankings).
    # Updates the source @data with serializable DB entities.
    # Currently, used for debugging purposes only.
    def solve
      map_meeting_and_sessions
      map_teams_and_swimmers
      map_events_and_results
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the GogglesDb::Season specified with the constructor.
    attr_accessor :season

    # Returns the whole internal data hash, "as is".
    #
    # == Notes on structure:
    #
    # Beside storing the already parsed source data, the data Hash will store additional keys
    # for each additional entity parsed.
    #
    # For any new row that needs to be created because missing from the database, its corresponding
    # "plain" column values will be stored is another dedicated Hash or Array of instance, each one usually
    # wrapped with a single Import::Entity and indexed with the original source name/code text from
    # the parsing.
    #
    # === Example:
    #
    #  { 'SwimmingPool' => [
    #      'name of the pool' => <Import::Entity pool 1, bindings: ['city' => 'key name of missing city'] >,
    #      'another pool' => <Import::Entity pool 2, bindings: []> # <=(when city_id is present)
    #    ]
    #  }
    #
    #  { 'City' => [
    #      'city name 1' => <Import::Entity city 1, bindings: []> # <=(city to be created from scratch)
    #    ]
    #  }
    #
    #
    # == Supported array/hash of entities:
    #
    # Each one of the following (apart from 'season_id'), being some kind of structure holding Import::Entity
    # instances, may have an associated #bindings list, used to store the references to the keys or
    # indexes used to lookup any missing associated entities as in the example before.
    #
    # The binding references will be filled-in only when the corresponding associated entities does not
    # have an ID because it needs to be created from scratch.
    # *Bindings storing entities with IDs will be considered viable for update.*
    #
    # - 'season_id' => special key, referencing directly the season ID specified with the constructor
    #
    # - 'meeting' => single, Import::Entity; wraps the "solved" Meeting entity;
    #
    # - 'meeting_session' => *Array*, Import::Entity rows; wraps the corresponding entity;
    #                        will reference: 'swimming_pool' => by source key name (only when entity needs to be created);
    #
    # - 'swimming_pool' => Hash, Import::Entity rows; wraps any SwimmingPool to be created or updated;
    #                      will reference: 'city' => by source key name (only when entity needs to be created);
    #
    # - 'city' => Hash, Import::Entity rows; wraps any City to be created or updated;
    #
    # - 'team' => Hash, Import::Entity rows; wraps any Team to be created or updated;
    # - 'team_affiliation' => Hash, Import::Entity rows; wraps any TeamAffiliatiom to be created or updated;
    #
    # - 'swimmer' => Hash, Import::Entity rows; wraps any Swimmer to be created or updated;
    # - 'badge'   => Hash, Import::Entity rows; wraps any (Swimmer-only) Badge to be created or updated;
    #
    # - 'meeting_event' => *Hash*, Import::Entity rows; wraps the corresponding entity;
    #                      will reference: 'meeting_session' => by index (only when session is new);
    #
    # - 'meeting_program' => *Hash*, Import::Entity rows; wraps the corresponding entity;
    #                        will reference: 'meeting_event' => by coded name);
    #
    # - 'meeting_individual_result' => *Hash*, Import::Entity rows; wraps the corresponding entity;
    #                                  will reference: 'meeting_program' => by coded name);
    #
    # - 'meeting_relay_result' => *Hash*, Import::Entity rows; wraps the corresponding entity;
    #                             will reference: 'meeting_program' => by coded name);
    #
    attr_accessor :data

    # Flag which is +true+ only when the parsed file has been found with a "retry" data section.
    # This implies that the file must be crawled again from its datasource in order to get the full results.
    # The file can still be processed normally, but the whole subsection with the retry will be missing from the resulting data Hash.
    attr_accessor :retry_needed

    #-- ------------------------------------------------------------------------
    #++

    # Mapper and setter for the Meeting main row and its sibling MeetingSessions
    # (each entity wrapped as an Import::Entity).
    #
    # == Resets & recomputes:
    # - @data['season_id'] => current Season
    # - @data['meeting'] => new or existing Meeting (as an Import::Entity value object)
    # - @data['meeting_session'] => array of new or existing MeetingSession instance (each one as an Import::Entity value object)
    #
    # == Returns
    # The array of Import::Entity wrapping the resulting candidate MeetingSession rows.
    def map_meeting_and_sessions
      @data['season_id'] = @season.id
      main_city_name, _area_code, _remainder = Parser::CityName.tokenize_address(@data['address1'])
      # Store all the Import::Entity wrappers in the data hash:
      @data['meeting'] = find_or_prepare_meeting(@data['name'], main_city_name)
      map_sessions
    end

    # Assuming <tt>@data['meeting'].row</tt> already contains a Meeting instance,
    # this will recreate from scratch the array of meeting sessions bound to the
    # current Meeting.
    #
    # == Resets & recomputes:
    # - @data['meeting_session'] => array of new or existing MeetingSession instance (each one as an Import::Entity value object)
    #
    # == Returns
    # The array of Import::Entity wrapping the resulting candidate MeetingSession rows.
    def map_sessions
      meeting = cached_instance_of('meeting', nil)
      # Prioritize existing sessions over the one from the parsed data:
      if meeting && meeting.id.present? && meeting.meeting_sessions.present?
        @data['meeting_session'] = meeting.meeting_sessions.map do |meeting_session|
          session = find_or_prepare_session(
            meeting:,
            session_order: meeting_session.session_order,
            date_day: meeting_session.scheduled_date&.day,
            date_month: Parser::SessionDate::MONTH_NAMES[meeting_session.scheduled_date&.month&.- 1],
            date_year: meeting_session.scheduled_date&.year,
            scheduled_date: meeting_session.scheduled_date,
            pool_name: meeting_session.swimming_pool&.name,
            address: meeting_session.swimming_pool&.address,
            pool_length: meeting_session.swimming_pool&.pool_type&.code,
            day_part_type: meeting_session.day_part_type
          )
          session.add_bindings!('meeting' => @data['name'])
          session
        end.compact # (Don't store nils in the array)
        return @data['meeting_session']
      end

      session1 = find_or_prepare_session(
        meeting:,
        session_order: 1,
        date_day: @data['dateDay1'],
        date_month: @data['dateMonth1'],
        date_year: @data['dateYear1'],
        pool_name: @data['venue1'],
        address: @data['address1'],
        pool_length: @data['poolLength']
        # day_part_type: GogglesDb::DayPartType.afternoon (currently no data for this)
      )
      session1.add_bindings!('meeting' => @data['name'])
      # Set the meeting official date to the one from the first session if the meeting is new:
      @data['meeting'].row.header_date = session1.row.scheduled_date if meeting.header_date.blank?

      # Prepare a second session if additional dates are given:
      session2 = if @data['dateDay2'].present? && @data['dateMonth2'].present? && @data['dateYear2'].present?
                   find_or_prepare_session(
                     meeting:,
                     session_order: 2,
                     date_day: @data['dateDay2'],
                     date_month: @data['dateMonth2'],
                     date_year: @data['dateYear2'],
                     pool_name: @data['venue2'].presence || @data['venue1'],
                     address: @data['address2'].presence || @data['address1'],
                     pool_length: @data['poolLength']
                     # day_part_type: GogglesDb::DayPartType.morning (currently no data for this)
                   )
                 end
      session2&.add_bindings!('meeting' => @data['name'])
      # Return just an Array with all the defined sessions in it:
      @data['meeting_session'] = [session1, session2].compact
    end

    # Mapper and setter for the list of unique teams & swimmers.
    #
    # Looping on the array of sections & result rows in the data, this extracts all team & swimmer names
    # while building up the 2 Hashes containing the team & swimmer meta-objects.
    # Each is keyed by the unique string names found in the results, storing as value a custom object
    # that wraps all the useful entities tied to either the Team or the Swimmer.
    #
    # == Resets & recomputes:
    # - @data['team'] => the Hash of (unique) Team meta-object instances ("name as key" => "Import::Entity value object")
    # - @data['team_affiliation'] => the Hash of (unique) TeamAffiliation meta-object instances ("name as key" => "Import::Entity value object")
    # - @data['swimmer'] => the Hash of (unique) Swimmer meta-object instances ("name as key" => "Import::Entity value object")
    #
    # == Clears but doesn't recompute:
    # - @data['badge'], because it will be filled-in during MIR mapping
    #
    def map_teams_and_swimmers(skip_broadcast = false)
      # Clear the lists:
      @data['team'] = {}
      @data['team_affiliation'] = {}
      @data['swimmer'] = {}
      @data['badge'] = {}
      total = @data['sections'].count
      section_idx = 0

      @data['sections'].each do |sect| # rubocop:disable Metrics/BlockLength
        section_idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', { msg: 'map_teams_and_swimmers', progress: section_idx, total: }) unless skip_broadcast
        # If the section contains a 'retry' subsection it means the crawler received some error response during
        # the data crawl and the result file is missing the whole result subsection.
        # (ALSO: we're not mapping team names from the rankings or the stats)

        # Search for specific sections presence that may act as a flag for skipping:
        next if sect['retry'].present? || sect['ranking'].present? || sect['stats'].present? || sect['rows'].blank?

        _event_type, category_type = Parser::EventType.from_l2_result(sect['title'], @season)

        # For parsed PDFs, the category code may be already set in section and the above may be nil:
        category_type = detect_ind_category_from_code(sect['fin_sigla_categoria']) if sect['fin_sigla_categoria'].present? && category_type.blank?
        # NOTE: category_type can still be nil at this point for some formats (relays, usually)
        # If this happens:
        # - category esteem is delegated to relay result & swimmer mapping inside #map_and_return_badge()
        # - when it's not a relay and the category code is missing, usually the format is mis-interpreted or needs debugging

        # Don't use an #each block here as we're going to modify the data structure in place
        # removing/ignoring the rows that aren't processable (no team names w/o a matching result elsewhere):
        row_idx = 0
        while row_idx < sect['rows'].count
          row = sect['rows'][row_idx]
          team_name = row['team']

          # RELAYS:
          if team_name.present? && row['relay'].present?
            Rails.logger.debug { "\r\n\r\n*** TEAM '#{team_name}' (relay) ***" } if @toggle_debug
            team = map_and_return_team(team_key: team_name)
            team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
            # This should never occur at this point (unless data is corrupted):
            raise("No team or team_affiliation ENTITY for '#{team_name}'!") if team.blank? || team_affiliation.blank?

            (1..MAX_SWIMMERS_X_RELAY).each do |swimmer_idx|
              swimmer_name = row["swimmer#{swimmer_idx}"]
              year_of_birth = row["year_of_birth#{swimmer_idx}"]
              # ('sex' can be extracted from event section or category section when missing)
              gender_type_code = /[mf]/i.match?(sect['fin_sesso'].to_s) ? sect['fin_sesso'] : row["gender_type#{swimmer_idx}"]
              next unless swimmer_name.present? && year_of_birth.present?

              swimmer_key, swimmer = map_and_return_swimmer(swimmer_name:, year_of_birth:, gender_type_code:, team_name:)
              # NOTE: usually badge numbers won't be added to relay swimmers due to limited space,
              #       so we revert to the default value (nil => '?')
              # NOTE 2: #map_and_return_badge will handle nil or relay category types with #post_compute_ind_category_code(YOB)
              badge = map_and_return_badge(swimmer:, swimmer_key:, team:, team_key: team_name,
                                           team_affiliation:, category_type:)
              # This should never occur at this point (unless data is corrupted):
              if swimmer_key.blank? || swimmer.blank? || badge.blank?
                raise("No swimmer_key, swimmer or badge ENTITY for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code})!")
              end
            end

          # INDIV. RESULTS:
          elsif row['relay'].blank?
            # WARNING: sometimes the team_name may be blank for some formats, but we can still recover from this
            #          if we have already imported some of the same meeting results.
            #          (typical case: processing a more detailed PDF file for adding the lap timings of some meeting
            #           results previously imported with a web-crawl run)
            swimmer_name = row['name']
            year_of_birth = row['year']
            gender_type_code = row['sex']
            badge_code = "#{row['badge_region']}-#{row['badge_num']}" if row['badge_region'].present? && row['badge_num'].present?
            next unless swimmer_name.present? && year_of_birth.present?

            # If we have already at least a MIR or a MRR linked to the same swimmer, we can use that team,
            # otherwise we simply cannot proceed:
            team = if team_name.blank?
                     map_and_return_team_from_matching_mir(swimmer_name, year_of_birth, gender_type_code)
                   else
                     map_and_return_team(team_key: team_name)
                   end
            # Team entity still not set? Kill the row and continue:
            if team.blank?
              Rails.logger.warn("Unable to find a matching team for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code})! Result row KILLED.")
              sect['rows'][row_idx] = nil
              sect['rows'].compact!
              # (Do not progress the row index as we're already shortening the array)
              next
            end

            update_swimmer_key = team_name.blank?
            row['team'] = team_name = team.name if team_name.blank? # Re-assign the team name in case we searched for an existing MIR
            Rails.logger.debug { "\r\n\r\n*** TEAM '#{team_name}' (ind.res.) ***" } if @toggle_debug
            team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
            swimmer_key, swimmer = map_and_return_swimmer(swimmer_name:, year_of_birth:, gender_type_code:, team_name:)

            # NOTE: #map_and_return_badge will handle nil or relay category types with #post_compute_ind_category_code(YOB)
            badge = map_and_return_badge(swimmer:, swimmer_key:, team:, team_key: team_name,
                                         team_affiliation:, category_type:, badge_code:)
            # Update any other entity referring/bound to this (swimmer & team):
            update_partial_swimmer_key(swimmer_key, team_name) if update_swimmer_key
            # This should never occur at this point (unless data is corrupted):
            if team_affiliation.blank? || badge.blank? || swimmer.blank?
              raise("No team_affiliation, badge, or swimmer ENTITY for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code})!")
            end
          end

          row_idx += 1
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Mapper and setter for the list of unique events & results.
    #
    # == Resets & recomputes:
    # - @data['meeting_event'] => the Hash of (unique) Import::Entity-wrapped MeetingEvents.
    # - @data['meeting_program'] => the Hash of (unique) Import::Entity-wrappedMeetingPrograms.
    # - @data['meeting_individual_result'] => the Hash of (unique) Import::Entity-wrapped MeetingIndividualResults.
    # - @data['lap'] => the Hash of (unique) Import::Entity-wrapped Laps.
    # - @data['meeting_relay_result'] => the Hash of (unique) Import::Entity-wrapped MeetingRelayResults.
    # - @data['meeting_relay_swimmer'] => the Hash of (unique) Import::Entity-wrapped MeetingRelaySwimmers.
    # - @data['relay_lap'] => the Hash of (unique) Import::Entity-wrapped RelayLaps.
    # - @data['meeting_team_score'] => the Hash of (unique) Import::Entity-wrapped MeetingTeamScores.
    #
    # == Note:
    # Currently, no data about the actual session in which the event was performed is provided:
    # all events (& programs) are forcibly assigned to just the first Meeting session found.
    # (Actual session information is usually available only on the Meeting manifest page.)
    #
    # FUTUREDEV: obtain manifest + parse it to get the actual session information.
    #
    # rubocop:disable Metrics/BlockLength
    def map_events_and_results
      # Clear the internal entity mappings:
      @data['meeting_event'] = {}
      @data['meeting_program'] = {}
      @data['meeting_individual_result'] = {}
      @data['meeting_relay_result'] = {}
      @data['lap'] = {}
      @data['relay_lap'] = {}
      @data['meeting_relay_swimmer'] = {}
      @data['meeting_team_score'] = {}
      total = @data['sections'].count
      section_idx = 0

      meeting = cached_instance_of('meeting', nil)
      msession_idx = 0 # TODO: find a way to change session number (only in manifest?)
      event_order = 0
      program_order = 0
      curr_category_type = nil
      meeting_session = cached_instance_of('meeting_session', msession_idx)

      # Detect if team & swimmer mapping has been skipped and force-run it:
      # (This shall happen only once whenever method #map_events_and_results()
      # gets called *before* #map_teams_and_swimmers()).
      first_team_name = @data['sections']&.first&.[]('rows')&.first&.fetch('team', nil)
      if @data['sections'].present? && (first_team_name.blank? || !entity_present?('team_affiliation', first_team_name))
        map_teams_and_swimmers # (No need to skip progress report if we launch this before the loop below)
      end

      # Map programs & events:
      @data['sections'].each do |sect|
        section_idx += 1
        # --- MeetingTeamScore --- find/create unless key is present (stores just the first unique key found):
        if sect['ranking'].present?
          ActionCable.server.broadcast('ImportStatusChannel', { msg: 'map_rankings', progress: section_idx, total: })
          process_team_score(rows: sect['rows'], meeting:)
          next
        end

        ActionCable.server.broadcast('ImportStatusChannel', { msg: 'map_events_and_results', progress: section_idx, total: })
        # Search for specific sections presence that may act as a flag for skipping:
        # (We're not currently going to store the parsed statistics in the DB)
        next if sect['retry'].present? || sect['stats'].present?

        # (Example section 'title': "50 Stile Libero - M25")
        event_type, category_type = Parser::EventType.from_l2_result(sect['title'], @season)

        # For parsed PDFs, the category code may be already set in section and the above may be nil:
        category_type = detect_ind_category_from_code(sect['fin_sigla_categoria']) if sect['fin_sigla_categoria'].present? && category_type.nil?

        # Store current category type in case the next one is not defined due to a DSQ ranking:
        curr_category_type = category_type if category_type.is_a?(GogglesDb::CategoryType)
        # Use previous category type in case the current one isn't found (possible DSQ ranking):
        category_type = curr_category_type if category_type.blank? && curr_category_type.is_a?(GogglesDb::CategoryType)

        gender_type = select_gender_type(sect['fin_sesso'])
        # Use a fixed key-index of 0 for the meeting session as long as we can't
        # determine which one it is from the parsed results file:
        event_key = event_key_for(0, event_type.code)

        # --- Pre-process MRR for unknown gender codes ---
        # In case it's a relay with an unclear/unset gender code,
        # let's try to detect the gender of the section from the swimmers of its first result:
        # (ASSUMES a dedicated section for each gender/category change)
        if (gender_type.nil? || category_type.nil?) && event_type.relay?
          Rails.logger.debug("\r\n    ---> pre-scanning MRR due to nil GenderType...") if @toggle_debug
          gender_type = preprocess_mrr_for_gender_code(row: sect['rows'].first, category_type:)
        end
        # (NOTE: gender_type && category_type may still be nil at this point for DSQ relays)
        # Can't store results if we can't be sure which category/gender they belong to:
        if gender_type.nil? || category_type.nil?
          Rails.logger.warn("\r\n    ---> SKIPPING SECTION STORAGE due to missing category_type OR gender_type!")
          Rails.logger.warn("\r\n    >>>> section: #{sect.inspect}")
          # DEBUG ----------------------------------------------------------------
          binding.pry
          # ----------------------------------------------------------------------
          next
        end

        program_key = program_key_for(event_key, category_type.code, gender_type.code)

        # --- MeetingEvent --- find/create unless key is present (stores just the first unique key found):
        Rails.logger.debug { "\r\n\r\n*** EVENT '#{event_key}' ***" } if @toggle_debug
        unless entity_present?('meeting_event', event_key)
          event_order += 1
          Rails.logger.debug { "    ---> '#{event_key}' n.#{event_order} (+)" } if @toggle_debug
          mevent_entity = find_or_prepare_mevent(
            meeting:, meeting_session:, session_index: msession_idx,
            event_type:, event_order:
          )
          add_entity_with_key('meeting_event', event_key, mevent_entity)
        end

        # --- MeetingProgram --- find/create unless key is present (as above):
        unless entity_present?('meeting_program', program_key)
          program_order += 1
          meeting_event = @data['meeting_event'][event_key].row
          pool_key = cached_instance_of('meeting_session', msession_idx, 'bindings')&.fetch('swimming_pool', nil)
          swimming_pool = meeting_session.swimming_pool || cached_instance_of('swimming_pool', pool_key)
          mprogram_entity = find_or_prepare_mprogram(
            meeting_event:, event_key:,
            pool_type: swimming_pool.pool_type,
            category_type:, gender_type:, event_order: program_order
          )
          add_entity_with_key('meeting_program', program_key, mprogram_entity)
        end

        # Build up the list of results:
        sect['rows']&.each do |row|
          meeting_program = cached_instance_of('meeting_program', program_key)

          if event_type.relay?
            process_mrr_and_mrs(
              row:, category_type:, event_type:,
              mprg: meeting_program, mprg_key: program_key
            )

          else
            process_mir_and_laps(
              row:, category_type:, event_type:,
              mprg: meeting_program, mprg_key: program_key
            )
          end
        end
      end
      return if @data['sections'].present?

      # Integrate the list with data already existing in the DB in case there are no sections at all:
      # (so that we get a glimpse on the page on what has already been imported before)
      map_events_from_db
      map_programs_from_db
    end
    # rubocop:enable Metrics/BlockLength
    #-- ------------------------------------------------------------------------
    #++

    # Integration for {#map_events_and_results} for when the 'sections' array is empty.
    # This method looks for any existing MeetingEvent data inside the DB (only),
    # integrating the cache with any existing row as a cached entity.
    def map_events_from_db
      @data&.fetch('meeting_session', []).each_with_index do |msession_hash, msession_idx|
        meeting_session_id = msession_hash.fetch('row', {}).fetch('id', nil) if msession_hash.is_a?(Hash)
        meeting_session_id = msession_hash.row.id if msession_hash.respond_to?(:row) && msession_hash.row.present?
        next unless meeting_session_id

        event_order = 0
        # Fail fast: (ASSERT: if a MSession row has been cached, we expect to find it in the DB also)
        meeting_session = GogglesDb::MeetingSession.find(meeting_session_id)
        Rails.logger.debug { "\r\n\r\n*** Fetching EVENTS from DB for MSession #{meeting_session_id}..." } if @toggle_debug

        # Retrieve all its associated events:
        meeting_session.meeting_events.each do |meeting_event|
          event_type = meeting_event.event_type
          event_key = event_key_for(msession_idx, event_type.code)
          # Add any missing event as a cached entity even if they aren't referenced yet by the JSON file:
          # (data['sections'] will be empty when results haven't been published yet)
          unless entity_present?('meeting_event', event_key)
            event_order += 1
            Rails.logger.debug { "    ---> '#{event_key}' n.#{event_order} (+)" } if @toggle_debug
            mevent_entity = Import::Entity.new(row: meeting_event, matches: [], bindings: { 'meeting_session' => msession_idx })
            add_entity_with_key('meeting_event', event_key, mevent_entity)
          end
        end
      end
    end

    # Integration for {#map_events_and_results} for when the 'sections' array is empty.
    # This method looks for any existing MeetingProgram data inside the DB (only),
    # integrating the cache with any existing row as a cached entity.
    def map_programs_from_db
      @data&.fetch('meeting_event', {}).each do |event_key, mevent_hash|
        meeting_event_id = mevent_hash.fetch('row', {}).fetch('id', nil) if mevent_hash.is_a?(Hash)
        meeting_event_id = mevent_hash.row.id if mevent_hash.respond_to?(:row) && mevent_hash.row.present?
        next unless meeting_event_id

        program_order = 0
        # Fail fast: (ASSERT: if a row has been cached, we expect to find it in the DB also)
        meeting_event = GogglesDb::MeetingEvent.find(meeting_event_id)
        Rails.logger.debug { "\r\n\r\n*** Fetching PROGRAMS from DB for MEvent #{meeting_event_id}..." } if @toggle_debug

        # Retrieve all its associated programs:
        meeting_event.meeting_programs.each do |meeting_program|
          category_type = meeting_program.category_type
          gender_type = meeting_program.gender_type
          program_key = program_key_for(event_key, category_type.code, gender_type.code)
          # Add any missing program as a cached entity even if they aren't referenced yet by the JSON file:
          unless entity_present?('meeting_program', program_key)
            program_order += 1
            Rails.logger.debug { "    ---> '#{program_key}' n.#{program_order} (+)" } if @toggle_debug
            mprogram_entity = Import::Entity.new(row: meeting_program, matches: [], bindings: { 'meeting_event' => event_key })
            add_entity_with_key('meeting_program', program_key, mprogram_entity)
          end
        end
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    # Finds or prepares the creation of a Meeting instance (wrapped into an <tt>Import::Entity<tt>)
    # given its description and its city name.
    #
    # == Params:
    # - <tt>description</tt> => Meeting description
    # - <tt>main_city_name</tt> => main city name of the Meeting
    #
    # == Returns:
    # An <tt>Import::Entity<tt> wrapping the target row together with a list of all possible candidates,
    # when found.
    #
    # <tt>Import::Entity#matches<tt> is the array of possible row candidates sorted by
    # result weight or probability (it can be used to build up select dropdowns as a
    # collection of values).
    #
    def find_or_prepare_meeting(description, main_city_name)
      cmd = GogglesDb::CmdFindDbEntity.call(
        GogglesDb::Meeting,
        { description:, season_id: @season.id, toggle_debug: @toggle_debug == 2 }
      )
      if cmd.successful? && cmd.result.season_id == @season.id
        matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
        return Import::Entity.new(row: cmd.result, matches:)
      end

      meeting_code = GogglesDb::Normalizers::CodedName.for_meeting(description, main_city_name)
      edition, name_no_edition, edition_type_id = GogglesDb::Normalizers::CodedName.edition_split_from(description)
      new_row = GogglesDb::Meeting.new(
        season_id: @season.id,
        description:,
        code: meeting_code,
        header_year: @season.header_year,
        edition_type_id:,
        edition:,
        autofilled: true,
        timing_type_id: GogglesDb::TimingType::AUTOMATIC_ID,
        notes: "\"#{name_no_edition}\", c/o: #{main_city_name}"
      )
      matches = [new_row] + GogglesDb::Meeting.where(season_id: @season.id)
                                              .where('meetings.code LIKE ?', "%#{meeting_code}%")
                                              .to_a
      Import::Entity.new(row: new_row, matches:)
    end

    # Finds or prepares the creation of a City instance given its name included in a text address.
    #
    # == Params:
    # - <tt>id</tt> => City ID, if already knew (shortcut a few queries)
    # - <tt>venue_address</tt> => a swimming_pool/venue address that includes the city name
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates,
    # when found. <tt>Import::Entity#matches<tt> is the array of possible row candidates, as above.
    #
    def find_or_prepare_city(id, venue_address)
      # FINDER: -- City --
      # 1. Existing:
      existing_row = GogglesDb::City.find_by(id:) if id.to_i.positive?
      return Import::Entity.new(row: existing_row) if existing_row.present?

      # 2. Smart search #1:
      city_name, area_code, _remainder = Parser::CityName.tokenize_address(venue_address)
      cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::City, { name: city_name, toggle_debug: @toggle_debug == 2 })
      if cmd.successful?
        matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
        return Import::Entity.new(row: cmd.result, matches:)
      end

      # 3. Smart search #2 || New row:
      # Try to find a match using the internal ISOCity database first:
      country = ISO3166::Country.new('IT')
      cmd = GogglesDb::CmdFindIsoCity.call(country, city_name)
      new_row = if cmd.successful?
                  GogglesDb::City.new(
                    name: cmd.result.respond_to?(:accentcity) ? cmd.result.accentcity : cmd.result.name,
                    country_code: country.alpha2,
                    country: country.iso_short_name,
                    area: area_code,
                    latitude: cmd.result.latitude,
                    longitude: cmd.result.longitude
                  )
                else
                  # Use an educated guess:
                  GogglesDb::City.new(name: city_name, area: area_code, country_code: 'IT', country: 'Italia')
                end
      # NOTE: cmd.matches will report either the empty matches if no match was found, or the list of candidates otherwise.
      matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
      Import::Entity.new(row: new_row, matches:)
    end

    # Finds or prepares the creation of a SwimmingPool instance given the parameters.
    #
    # == Params:
    # - <tt>id</tt> => swimming pool ID, if already knew (shortcut a few queries)
    # - <tt>pool_name</tt> => swimming pool name
    # - <tt>address</tt> => swimming pool address
    # - <tt>pool_length</tt> => swimming pool length in meters, as a string
    # - <tt>lanes_number</tt> => number of available lanes, as a string (default: '8' but can be +nil+)
    # - <tt>phone_number</tt> => phone number of the pool, when available (default: +nil+)
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates,
    # when found.
    #
    # The entity wrapper stores:
    # - <tt>#row<tt> => main row model candidate;
    # - <tt>#matches<tt> => Array of possible or alternative row candidates, including the first/best;
    # - <tt>#bindings<tt> => Hash of associations needed especially when the association row is new.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_pool(id, pool_name, address, pool_length, lanes_number = '8', phone_number = nil)
      # Already existing & found?
      existing_row = GogglesDb::SwimmingPool.find_by(id:) if id.to_i.positive?

      # FINDER: -- City --
      city_key_name, _area_code, remainder_address = Parser::CityName.tokenize_address(address)
      city_entity = find_or_prepare_city(existing_row&.city_id, address)
      # Always store in cache the sub-entity found:
      # (this is currently the only place where we may cache the City entity found; 'team' doesn't do this - yet)
      add_entity_with_key('city', city_key_name, city_entity)

      # FINDER: -- Pool --
      # 1. Existing:
      bindings = { 'city' => city_key_name }
      return Import::Entity.new(row: existing_row, bindings:) if existing_row.present?

      # 2. Smart search:
      pool_type = GogglesDb::PoolType.mt_25 # Default type
      pool_type = GogglesDb::PoolType.mt_50 if /50/i.match?(pool_length)
      cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::SwimmingPool, { name: pool_name, pool_type_id: pool_type.id }) if pool_name.present?
      if cmd&.successful?
        # Force-set the pool city_id to the one on the City entity found (only if the city row has indeed an ID and that's still
        # unset on the pool just found:
        cmd.result.city_id = city_entity.row&.id if cmd.result.city_id.to_i.zero? && city_entity.row&.id.to_i.positive?
        matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
        return Import::Entity.new(row: cmd.result, matches:, bindings:)
      end

      # 3. New row:
      # Parse nick_name using pool name + address:
      best_city_name = city_entity.row&.name || city_key_name
      nick_name = GogglesDb::Normalizers::CodedName.for_pool(pool_name, best_city_name, pool_type.code)
      new_row = GogglesDb::SwimmingPool.new(
        city_id: city_entity.row&.id,
        pool_type_id: pool_type.id,
        name: pool_name,
        nick_name:,
        address: remainder_address,
        phone_number:,
        lanes_number:
      )
      # Add the bindings to the new entity row (even if city_entity.row has an ID):
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a MeetingSession instance given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting</tt> => the current Meeting instance (single, best candidate found)
    # - <tt>:session_order</tt> => default: 1
    #
    # - <tt>:date_day</tt> => text date day
    # - <tt>:date_month</tt> => text date month (allegedly, in Italian; could be abbreviated)
    # - <tt>:date_year</tt> => text date year
    #
    # - <tt>:scheduled_date</tt> => scheduled_date, if already available; has priority over the 3-field date format
    #
    # - <tt>:pool_name</tt> => full name of the swimming pool
    # - <tt>:address</tt> => full text address of the swimming pool (must include city name)
    # - <tt>:pool_length</tt> => default '25'
    #
    # - <tt>:day_part_type_id</tt> => defaults to GogglesDb::DayPartType::MORNING_ID
    #
    # If the Meeting instance has a valid ID and has existing associated MeetingSession rows to it,
    # these will take precendence over the rest of the specified parameters, provided their session_order
    # is properly set (uses the Meeting#id & the session_order to discriminate them).
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # The entity wrapper stores:
    # - <tt>#row<tt> => main row model candidate;
    # - <tt>#matches<tt> => Array of possible or alternative row candidates, including the first/best;
    # - <tt>#bindings<tt> => Hash of keys pointing to the correct association rows stored at root level in the #data hash member.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_session(meeting:, date_day:, date_month:, date_year:, pool_name:, address:,
                                scheduled_date: nil, session_order: 1, pool_length: '25',
                                day_part_type: GogglesDb::DayPartType.morning)
      # 1. Find existing:
      iso_date = scheduled_date || Parser::SessionDate.from_l2_result(date_day, date_month, date_year)
      domain = GogglesDb::MeetingSession.where(meeting_id: meeting&.id, session_order:)
      pool_entity = find_or_prepare_pool(domain.first&.swimming_pool_id, pool_name, address, pool_length)
      # Always store in cache the sub-entity found:
      add_entity_with_key('swimming_pool', pool_name, pool_entity)
      bindings = { 'meeting' => meeting.description, 'swimming_pool' => pool_name }

      # Force-set the association id in the main row found, only if the sub-entity has an ID and is not set on the main row:
      if domain.present? # (then we're almost done)
        domain.first.swimming_pool_id = pool_entity.row&.id if domain.first.swimming_pool_id.to_i.zero? &&
                                                               pool_entity.row&.id.to_i.positive?
        return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:)
      end

      # 2. New row:
      new_row = GogglesDb::MeetingSession.new(
        meeting_id: meeting&.id,
        swimming_pool: pool_entity.row,
        day_part_type_id: day_part_type.id,
        session_order:,
        scheduled_date: iso_date,
        description: "Sessione #{session_order}, #{iso_date}" # Use default supported locale only ('it' , as currently this is a FIN-specific type of parser)
      )
      # Add the bindings to the new entity row (even if pool_entity.row has an ID):
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a MeetingEvent instance given all of the following parameters.
    # == Context:
    # The main purpose of this method is to find a proper match between possibly new or existing
    # MEvents rows and existing/cached MSessions.
    #
    # == Params:
    # - <tt>:meeting</tt> => the parent Meeting instance (single, best candidate found or created)
    # - <tt>:meeting_session</tt> => the parent MeetingSession instance (single, best candidate found or created)
    # - <tt>:session_index</tt> => ordinal index (key) for the MeetingSession entity array stored at root level in the data Hash member
    # - <tt>:event_type</tt> => associated EventType
    # - <tt>:event_order</tt> => overall order of this event
    # - <tt>:heat_type</tt> => defaults to GogglesDb::HeatType.finals
    #
    # The Meeting instance is used to find and prioritize any existing MeetingEvent owned by the same Meeting
    # for the associated unique event type. If any such event is found on localhost, it's considered to be
    # the actual row to be updated.
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_mevent(meeting:, meeting_session:, session_index:, event_type:, event_order:, heat_type: GogglesDb::HeatType.finals)
      # Prioritize any existing meeting events:
      if meeting.present? && meeting.id.present? &&
         GogglesDb::MeetingEvent.joins(:meeting).includes(:meeting).exists?('meetings.id': meeting.id, event_type_id: event_type.id)
        existing_mev = GogglesDb::MeetingEvent.joins(:meeting).includes(:meeting)
                                              .where('meetings.id': meeting.id, event_type_id: event_type.id)
                                              .first
        # Find & assign the proper msession index in case the one being processed as parameter isn't the original one
        # in the existing row (we need to find a corresponding key/index inside the array of sessions):
        proper_msession_id = existing_mev.meeting_session_id
        proper_msession_idx = 0
        (0...@data['meeting_session'].count).each do |msession_idx|
          meeting_session = cached_instance_of('meeting_session', msession_idx)
          proper_msession_idx = msession_idx
          break if meeting_session&.id == proper_msession_id
        end
        return Import::Entity.new(
          row: existing_mev, matches: [existing_mev],
          bindings: { 'meeting_session' => proper_msession_idx }
        )
      end

      new_row = GogglesDb::MeetingEvent.new(
        meeting_session_id: meeting_session&.id, event_type_id: event_type.id,
        event_order:, heat_type_id: heat_type.id
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings: { 'meeting_session' => session_index })
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a MeetingProgram instance given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_event</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:event_key</tt> => MeetingEvent key in the entity sub-Hash stored at root level in the data Hash member
    # - <tt>:pool_type</tt> => associated PoolType
    # - <tt>:category_type</tt> => associated CategoryType
    # - <tt>:gender_type</tt> => associated GenderType
    # - <tt>:event_order</tt> => overall order of this event/program
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_mprogram(meeting_event:, event_key:, pool_type:, category_type:, gender_type:, event_order:)
      bindings = { 'meeting_event' => event_key }
      domain = GogglesDb::MeetingProgram.where(
        meeting_event_id: meeting_event&.id, pool_type_id: pool_type.id,
        category_type_id: category_type.id, gender_type_id: gender_type.id
      )
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      new_row = GogglesDb::MeetingProgram.new(
        meeting_event_id: meeting_event&.id, pool_type_id: pool_type.id,
        category_type_id: category_type.id, gender_type_id: gender_type.id,
        event_order:
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a Team instance given its name returning also its possible
    # alternative matches (when found).
    #
    # == Params:
    # - <tt>team_name</tt> => the name of the team to find or create (also, acts as key in the entity sub-Hash)
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    def find_or_prepare_team(team_name)
      cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Team, { name: team_name, toggle_debug: @toggle_debug == 2 })
      if cmd.successful?
        matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
        return Import::Entity.new(row: cmd.result, matches:)
      end

      new_row = GogglesDb::Team.new(name: team_name, editable_name: team_name)
      Import::Entity.new(row: new_row, matches: [new_row])
    end

    # Finds or prepares the creation of a team affiliation.
    # == Params:
    # - <tt>team</tt> => a valid GogglesDb::Team instance
    # - <tt>team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                        (may differ from the actual Team.name returned by a search)
    # - <tt>season</tt> => a valid GogglesDb::Season instance
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    def find_or_prepare_affiliation(team, team_key, season)
      # When present, team ID is assumed to be correct and has higher priority over name:
      domain = GogglesDb::TeamAffiliation.where(team_id: team&.id, season_id: season.id) if team&.id
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings: { 'team' => team_key }) if domain.present?

      # NOTE: *NEVER*, ever, use a partial match on affiliation name for detecting the domain above,
      #       unless the team is already existing! (If the team is not there, a correct affiliation surely isn't.)

      # ID can be nil for new rows, so we set the association using the new model directly where needed:
      new_row = GogglesDb::TeamAffiliation.new(team_id: team&.id, season_id: season.id, name: team.name)
      Import::Entity.new(row: new_row, matches: [new_row], bindings: { 'team' => team_key })
    end

    # Selects the GenderType given the parameter.
    # == Params:
    # - <tt>sex_code</tt> => coded sex string of the swimmer ('M' => male, 'F' => female, defaults to 'intermixed' when unknown)
    # == Returns:
    # A "direct" GogglesDb::GenderType instance (*not* an Import::Entity wrapper).
    # Will return +nil+ for blank sex codes.
    def select_gender_type(sex_code)
      return nil if sex_code.blank?
      return GogglesDb::GenderType.female if /f/i.match?(sex_code)
      return GogglesDb::GenderType.male if /m/i.match?(sex_code)

      GogglesDb::GenderType.intermixed
    end

    # Finds or prepares the creation of a Swimmer instance given its name returning also its possible
    # alternative matches (when found).
    #
    # For most data formats scenarios this will be safe to call even when the sex code is unknown.
    # (Depending on the already existing swimmer data.)
    #
    # == Params:
    # - <tt>swimmer_name</tt> => name of the swimmer to find or create
    # - <tt>year</tt> => year of birth of the swimmer
    # - <tt>sex_code</tt> => coded sex string of the swimmer ('M' => male, 'F' => female)
    #
    # == Returns two elements:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    def find_or_prepare_swimmer(swimmer_name, year, sex_code)
      gender_type = select_gender_type(sex_code) # WARNING: May result +nil+ for certain relay formats
      year_of_birth = year.to_i if year.to_i.positive?
      finder_opts = { complete_name: swimmer_name, toggle_debug: @toggle_debug == 2 }
      # Don't add nil params to the finder cmd as they may act as filters as well:
      finder_opts[:gender_type_id] = gender_type.id if gender_type.is_a?(GogglesDb::GenderType)
      finder_opts[:year_of_birth] = year.to_i if year.to_i.positive?

      cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Swimmer, finder_opts)
      # NOTE: cmd will find a result even for nil gender types, but it may fail for "totally new" swimmers
      #       added through a relay result!
      if cmd.successful?
        matches = cmd.matches.respond_to?(:map) ? cmd.matches.map(&:candidate) : cmd.matches
        return Import::Entity.new(row: cmd.result, matches:)
      end

      tokens = swimmer_name.split # ASSUMES: family name(s) first, given name(s) last
      if tokens.size == 2
        last_name = tokens.first
        first_name = tokens.last
      end
      if tokens.size == 3
        # Common italian double surname cases:
        if %w[DA DAL DALLA DALLE DE DEI DEL DELLA DELLE DEGLI DI DO LA LE LI LO].include?(tokens.first.upcase)
          last_name = tokens[0..1].join(' ')
          first_name = tokens.last
        else # Assume double name instead:
          last_name = tokens.first
          first_name = tokens[1..2].join(' ')
        end
      end
      if tokens.size > 3
        # Assume double surname by default:
        last_name = tokens[0..1].join(' ')
        first_name = tokens[2..].join(' ')
      end
      new_row = GogglesDb::Swimmer.new(
        complete_name: swimmer_name,
        first_name:,
        last_name:,
        year_of_birth:,
        # See notes above about the possibility that gender_type may still be nil at this point
        # NOTE ALSO THAT:
        # gender_type may be nil when the swimmer was searched in cache using
        # a team name in its key that was aggressively deleted with a data_fix#purge
        # without substitution of the existing binding keys with the remaining duplicate
        # found before the purge.
        # The "Purge" action is nevertheless required each time there's a possible duplicate in
        # new swimmers or teams to avoid errors due to duplicated rows during the commit phase.
        gender_type_id: gender_type.id,
        year_guessed: year_of_birth.to_i.zero?
      )
      Import::Entity.new(row: new_row, matches: [new_row])
    end

    # Finds or prepares the creation of a swimmer badge.
    #
    # == Params:
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:team_affiliation</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:category_type</tt> => a valid GogglesDb::CategoryType instance
    # - <tt>:badge_code</tt> => the string code of the badge, when available; defaults to '?'
    # - <tt>:entry_time_type</tt> => a valid GogglesDb::EntryTimeType instance; defaults to 'use timing from last race'
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_badge(swimmer:, swimmer_key:, team:, team_key:, team_affiliation:, category_type:,
                              badge_code: '?', entry_time_type: GogglesDb::EntryTimeType.last_race)
      # Swimmer & TA can be new, so we add them to the bindings Hash here:
      bindings = { 'swimmer' => swimmer_key, 'team_affiliation' => team_key, 'team' => team_key }
      domain = GogglesDb::Badge.where(swimmer_id: swimmer&.id, team_affiliation_id: team_affiliation&.id)
      if domain.present?
        badge_row = domain.first
        # Overwrite badge number only when previously unknown:
        badge_row.number = badge_code if badge_row.number == '?' && badge_code != '?' && badge_code.present?
        return Import::Entity.new(row: badge_row, matches: domain.to_a, bindings:)
      end

      # ID can be nil for new rows, so we set the association using the new model directly where needed:
      new_row = GogglesDb::Badge.new(
        swimmer_id: swimmer&.id,
        team_affiliation_id: team_affiliation&.id,
        team_id: team&.id,
        season_id: team_affiliation.season_id, # (ASSERT: this will be always set)
        category_type_id: category_type.id,
        entry_time_type_id: entry_time_type.id,
        number: badge_code || '?'
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a MeetingIndividualResult row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    #
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:team_affiliation</tt> => associated TeamAffiliation
    # - <tt>:badge</tt> => associated Badge
    # - <tt>:rank</tt> => integer ranking position
    # - <tt>:timing</tt> => Timing instance storing the total recorded time
    # - <tt>:score</tt> => Float score for "standard points" (using FIN scoring rules)
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_mir(meeting_program:, mprogram_key:, swimmer:, swimmer_key:, team:, team_key:,
                            team_affiliation:, badge:, rank:, timing:, score:, disqualify_type: '')
      bindings = {
        'meeting_program' => mprogram_key, 'swimmer' => swimmer_key, 'badge' => swimmer_key,
        'team_affiliation' => team_key, 'team' => team_key
      }
      domain = GogglesDb::MeetingIndividualResult.where(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id, swimmer_id: swimmer&.id
      )
      # Compromise: assume anything else beside "Falsa partenza" (code: 'GA') gets a nil code:
      # (will need to show the actual DSQ notes to get a label in the UI)
      dsq_code_type_id = GogglesDb::DisqualificationCodeType.find_by(code: 'GA').id if /falsa/i.match?(disqualify_type)
      if domain.present?
        mir_row = domain.first
        # Overwrite DSQ fields only when previously unknown:
        mir_row.rank = 0 if disqualify_type.present?
        mir_row.disqualified = disqualify_type.present? if disqualify_type.present? && !mir_row.disqualified
        mir_row.disqualification_notes = disqualify_type if disqualify_type.present?
        mir_row.disqualification_code_type_id = dsq_code_type_id if dsq_code_type_id.present?
        return Import::Entity.new(row: mir_row, matches: domain.to_a, bindings:)
      end

      rank = 0 if disqualify_type.present? # Force blank rank for DSQs
      new_row = GogglesDb::MeetingIndividualResult.new(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id,
        swimmer_id: swimmer&.id,
        team_affiliation_id: team_affiliation&.id,
        badge_id: badge&.id,
        rank:,
        minutes: timing&.minutes || 0,
        seconds: timing&.seconds || 0,
        hundredths: timing&.hundredths || 0,
        goggle_cup_points: 0.0, # (no data)
        team_points: 0.0, # (no data)
        standard_points: score || 0.0,
        meeting_points: 0.0, # (no data)
        reaction_time: 0.0, # (no data)
        disqualified: disqualify_type.present?,
        disqualification_notes: disqualify_type,
        disqualification_code_type_id: dsq_code_type_id
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a Lap row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => parent MeetingProgram key
    #
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:mir</tt> => a valid or new GogglesDb::MeetingIndividualResult instance
    # - <tt>:mir_key</tt> => parent MIR key in the entity sub-Hash stored at root level in the data Hash member.
    #
    # - <tt>:length_in_meters</tt> => length in meters (int)
    # - <tt>:abs_timing</tt> => Timing instance storing the absolute recorded time *from the start* of the heat
    # - <tt>:delta_timing</tt> => Timing instance storing the relative *delta* lap time
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_lap(meeting_program:, mprogram_key:, swimmer:, swimmer_key:, team:, team_key:,
                            mir:, mir_key:, length_in_meters:, abs_timing:, delta_timing:)
      bindings = {
        'meeting_program' => mprogram_key, 'swimmer' => swimmer_key, 'team' => team_key,
        'meeting_individual_result' => mir_key
      }
      domain = GogglesDb::Lap.where(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id, swimmer_id: swimmer&.id
      )
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      new_row = GogglesDb::Lap.new(
        meeting_program_id: meeting_program&.id,
        meeting_individual_result_id: mir&.id,
        swimmer_id: swimmer&.id,
        team_id: team&.id,
        length_in_meters:,
        # Make sure no nil timings:
        minutes: delta_timing&.minutes || abs_timing&.minutes || 0,
        seconds: delta_timing&.seconds || abs_timing&.minutes || 0,
        hundredths: delta_timing&.hundredths || abs_timing&.minutes || 0,
        minutes_from_start: abs_timing&.minutes || 0,
        seconds_from_start: abs_timing&.seconds || 0,
        hundredths_from_start: abs_timing&.hundredths || 0,
        reaction_time: 0.0 # (no data)
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists
    #-- -------------------------------------------------------------------------
    #++

    # Finds or prepares the creation of a MeetingRelayResult row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:team_affiliation</tt> => associated TeamAffiliation
    # - <tt>:rank</tt> => integer ranking position
    # - <tt>:timing</tt> => Timing instance storing the total recorded time
    # - <tt>:score</tt> => Float score for "standard points" (using FIN scoring rules)
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # == NOTE:
    # Assuming multiple MRR are possible for the same team & MPRG (same relay category),
    # the chosen candidate will always be the last domain row found.
    # In other words, the result shall be the last created MRR row found satisfying
    # the same parameter values as constraints.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_mrr(meeting_program:, mprogram_key:, team:, team_key:,
                            team_affiliation:, rank:, timing:, score:, disqualify_type: '')
      bindings = {
        'meeting_program' => mprogram_key, 'team_affiliation' => team_key, 'team' => team_key
      }
      domain = GogglesDb::MeetingRelayResult.where(
        meeting_program_id: meeting_program&.id, team_id: team&.id
      )
      # Compromise: assume generic "Nuotata irregolare" refers to 1st swimmer only:
      # (not true, but most of the times the label isn't more specific)
      dsq_code_type_id = GogglesDb::DisqualificationCodeType.find_by(code: 'RE1').id if /irregolare/i.match?(disqualify_type)
      if domain.present?
        mrr_row = domain.last
        # Overwrite DSQ fields only when previously unknown:
        mrr_row.rank = 0 if disqualify_type.present?
        mrr_row.disqualified = disqualify_type.present? if disqualify_type.present? && !mrr_row.disqualified
        mrr_row.disqualification_notes = disqualify_type if disqualify_type.present?
        mrr_row.disqualification_code_type_id = dsq_code_type_id if dsq_code_type_id.present?
        return Import::Entity.new(row: mrr_row, matches: domain.to_a, bindings:)
      end

      rank = 0 if disqualify_type.present? # Force blank rank for DSQs
      new_row = GogglesDb::MeetingRelayResult.new(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id,
        team_affiliation_id: team_affiliation&.id,
        rank:,
        minutes: timing&.minutes || 0,
        seconds: timing&.seconds || 0,
        hundredths: timing&.hundredths || 0,
        standard_points: score || 0.0,
        meeting_points: 0.0, # (no data)
        reaction_time: 0.0, # (no data)
        disqualified: disqualify_type.present?,
        disqualification_notes: disqualify_type,
        disqualification_code_type_id: dsq_code_type_id
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares the creation of a MeetingRelaySwimmer row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => parent MeetingProgram key
    # - <tt>:event_type</tt> => linked GogglesDb::EventType instance
    #
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search)
    #                            NOTE: this acts also as Badge key.
    #
    # - <tt>:badge</tt> => a valid or new GogglesDb::Badge instance
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:mir</tt> => a valid or new GogglesDb::MeetingIndividualResult instance
    # - <tt>:mir_key</tt> => parent MIR key in the entity sub-Hash stored at root level in the data Hash member.
    #
    # - <tt>:relay_order</tt> => phase order in the relay (usually 1..4)
    # - <tt>:length_in_meters</tt> => length in meters (int)
    # - <tt>:abs_timing</tt> => Timing instance storing the absolute recorded time *from the start* of the heat
    # - <tt>:delta_timing</tt> => Timing instance storing the relative *delta* lap time
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_rel_swimmer(meeting_program:, mprogram_key:, event_type:,
                                    swimmer:, swimmer_key:, team:, team_key:,
                                    mrr:, mrr_key:, badge:, relay_order:, length_in_meters:,
                                    abs_timing:, delta_timing:)
      bindings = {
        'meeting_program' => mprogram_key, 'meeting_relay_result' => mrr_key,
        'swimmer' => swimmer_key, 'badge' => swimmer_key, 'team' => team_key
      }
      domain = GogglesDb::MeetingRelaySwimmer.includes(:meeting_program, :team)
                                             .joins(:meeting_program, :team)
                                             .where(
                                               'meeting_programs.id': meeting_program&.id,
                                               'teams.id': team&.id, swimmer_id: swimmer&.id
                                             )
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      stroke_type_id = if event_type.stroke_type_id == GogglesDb::StrokeType::REL_INTERMIXED_ID && relay_order.positive?
                         [
                           GogglesDb::StrokeType::BACKSTROKE_ID,
                           GogglesDb::StrokeType::BREASTSTROKE_ID,
                           GogglesDb::StrokeType::BUTTERFLY_ID,
                           GogglesDb::StrokeType::FREESTYLE_ID
                         ].at(relay_order - 1)
                       else
                         event_type.stroke_type_id
                       end
      # DEBUG ----------------------------------------------------------------
      binding.pry if stroke_type_id.to_i < 1 || relay_order.to_i < 1 || relay_order.to_i > 4
      # ----------------------------------------------------------------------

      new_row = GogglesDb::MeetingRelaySwimmer.new(
        meeting_relay_result_id: mrr&.id,
        relay_order: relay_order || 0,
        swimmer_id: swimmer&.id,
        badge_id: badge&.id,
        stroke_type_id:,
        length_in_meters: length_in_meters || 0,
        # Make sure no nil timings:
        minutes: delta_timing&.minutes || 0,
        seconds: delta_timing&.seconds || 0,
        hundredths: delta_timing&.hundredths || 0,
        minutes_from_start: abs_timing&.minutes || 0,
        seconds_from_start: abs_timing&.seconds || 0,
        hundredths_from_start: abs_timing&.hundredths || 0,
        reaction_time: 0.0 # (no data)
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists
    #-- -------------------------------------------------------------------------
    #++

    # Finds or prepares the creation of a RelayLap row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => parent MeetingProgram key
    #
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:mrr</tt> => a valid or new GogglesDb::MeetingRelayResult instance
    # - <tt>:mrr_key</tt> => parent MRR key in the entity sub-Hash stored at root level in the data Hash member.
    # - <tt>:mrs</tt> => a valid or new GogglesDb::MeetingRelaySwimmer instance
    # - <tt>:mrs_key</tt> => parent MRS key in the entity sub-Hash stored at root level in the data Hash member.
    #
    # - <tt>:length_in_meters</tt> => length in meters (int)
    # - <tt>:abs_timing</tt> => Timing instance storing the absolute recorded time *from the start* of the heat
    # - <tt>:delta_timing</tt> => Timing instance storing the relative *delta* lap time
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    # rubocop:disable Metrics/ParameterLists
    def find_or_prepare_relay_lap(swimmer:, swimmer_key:, team:, team_key:,
                                  mrr:, mrr_key:, mrs:, mrs_key:,
                                  length_in_meters:, abs_timing:, delta_timing:)
      bindings = {
        'meeting_relay_result' => mrr_key, 'meeting_relay_swimmer' => mrs_key,
        'swimmer' => swimmer_key, 'team' => team_key
      }
      domain = GogglesDb::RelayLap.where(meeting_relay_swimmer_id: mrs&.id, length_in_meters:)
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      new_row = GogglesDb::RelayLap.new(
        meeting_relay_result_id: mrr&.id,
        meeting_relay_swimmer_id: mrs&.id,
        swimmer_id: swimmer&.id,
        team_id: team&.id,
        length_in_meters: length_in_meters || 0,
        # Make sure no nil timings:
        minutes: delta_timing&.minutes || abs_timing&.minutes || 0,
        seconds: delta_timing&.seconds || abs_timing&.minutes || 0,
        hundredths: delta_timing&.hundredths || abs_timing&.minutes || 0,
        minutes_from_start: abs_timing&.minutes || 0,
        seconds_from_start: abs_timing&.seconds || 0,
        hundredths_from_start: abs_timing&.hundredths || 0,
        reaction_time: 0.0, # (no data)
        position: 0 # (no data)
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists
    #-- -------------------------------------------------------------------------
    #++

    # Generalized helper for #find_or_prepare_lap or #find_or_prepare_rel_swimmer,
    # depending on distance in meters and the class of the specified result row.
    # Uses a prev_lap_timing instance to compute any missing timing values.
    #
    # == IMPORTANT NOTE ON EXTRACTING THE LAST LAP:
    # For relays, even the last lap is required as a field name in order to compute
    # the last timing delta. The 'timing' overall field won't be used.
    # So, for instance, in a 4x50=200m relay, the last lap field 'lap200' should be
    # included even if it's a duplicate of the 'timing' field.
    #
    # == Params:
    # - <tt>:meeting_program</tt> => the parent MeetingProgram instance (single, best candidate found or created)
    # - <tt>:mprogram_key</tt> => parent MeetingProgram key
    # - <tt>:event_type</tt> => linked GogglesDb::EventType instance
    #
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => Swimmer key in the entity sub-Hash stored at root level in the data Hash member
    #                            (may differ from the actual Swimmer.name returned by a search);
    #                            NOTE: this acts also as Badge key.
    #
    # - <tt>:badge</tt> => a valid or new GogglesDb::Badge instance for the current swimmer
    # - <tt>:team</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:mr_model</tt> => a valid parent result for the lap entity to be created; either a MIR, MRR or a MRS or a
    #                         new instance of the same model if none was found;
    #
    # - <tt>:mr_key</tt> => parent MIR/MRR/MRS key in the entity sub-Hash stored at root level in the data Hash member.
    #
    # - <tt>:row</tt> => data Hash containing the result row being processed;
    #
    # - <tt>:order</tt> => ordinal for the relay phase (usually 1..4);
    #                      e.g.: 2 for the 3rd 50m sub-lap of a 4x100m relay; (ignored for Laps or RelayLaps which uses the length)
    #
    # - <tt>:max_order</tt> => max value for the above ordinal relay phase (usually 4)
    #
    # - <tt>:length_in_meters</tt> => length in meters (int); must reflect the actual length of the phase or sub-phase
    #                                 that is bound to the lap timing to be processed;
    #                                 e.g.: 150 for the 3rd 50m sub-lap of a 4x100m relay;
    #
    # - <tt>:prev_lap_timing</tt> => Timing instance extracted from previous lap ("absolute" timing from start)
    #                                or a Timing.new instance for lap number zero; when set to +nil+ the delta
    #                                calculation will be skipped.
    #
    # - <tt>:sublap_index</tt> => when positive, allows creation of RelayLap rows if sub_phases is positive too
    #
    # - <tt>:sub_phases</tt> => total number of sub-phases or sub-laps; for long relays (i.e.: 4x200m), 3 sub-laps
    #                           1 MRS entity can be generated by simply calling this method for each available
    #                           (sub)lap length.
    # == Returns:
    # Returns the parsed lap Timing instance given current row data Hash and its key values;
    # +nil+ in case no lap was found for the specified distance in meters when already added as an entity.
    #
    # rubocop:disable Metrics/ParameterLists
    def extract_lap_timing_for(meeting_program:, mprogram_key:, event_type:,
                               swimmer:, swimmer_key:, badge:, team:, team_key:,
                               mr_model:, mr_key:, row:,
                               order:, max_order:, length_in_meters:, prev_lap_timing:,
                               sublap_index: 0, sub_phases: 0)
      lap_field_key = "lap#{length_in_meters}"
      delta_field_key = "delta#{length_in_meters}"
      # At least one of the two timing columns should be available in order to
      # extract any lap timings for any lap occurring before the last one.
      # If both are missing, lap processing should be skipped for this call.

      # But sub-lap processing should NOT be skipped even if both lap & delta are missing, using the
      # overall 'timing' field as final lap, so that we can add the last lap or MRS even when fields are missing.

      # Also, whenever we are processing a sub-relay lap (odd length / 50) and we don't have the
      # corresponding field value from the row, the processing SHOULD be always skipped regardless the current
      # ordering of the lap (since we can't infer delta or lap timings from the overall value).
      return if row[lap_field_key].blank? && row[delta_field_key].blank? && (order < max_order || (length_in_meters / 50).odd?)

      # Whenever both are missing and it's the last lap, assuming we have the previous lap timing
      # and the overall timing, we can compute both current lap & delta timings.

      # Extract both delta and abs lap timings from the row data, if the fields are present:
      # (the Parser method will return nil for blanks)
      lap_timing = Parser::Timing.from_l2_result(row[lap_field_key])
      delta_timing = Parser::Timing.from_l2_result(row[delta_field_key])
      # Make sure we fallback to the final timing if the lap timing is missing and the lap is the last one:
      lap_timing = Parser::Timing.from_l2_result(row['timing']) if (lap_timing.blank? || lap_timing.zero?) && order == max_order

      # Compute missing delta if lap_timing is present:
      if (delta_timing.blank? || delta_timing.zero?) && lap_timing&.positive?
        delta_timing = prev_lap_timing&.positive? ? lap_timing - prev_lap_timing : lap_timing
      end

      # Compute possible missing timing counterpart (both delta and abs lap):
      # NOTE: this will hardly work for MRR with MRS+RelayLaps, which rely on delta timings found during the parsing.
      if prev_lap_timing&.positive? || prev_lap_timing&.zero?
        delta_timing = lap_timing - prev_lap_timing if (delta_timing.blank? || delta_timing.zero?) && lap_timing&.positive?
        lap_timing = delta_timing + prev_lap_timing if (lap_timing.blank? || lap_timing.zero?) && delta_timing&.positive?
      end
      # At this point we should have both lap_timing and delta_timing; skip it otherwise:
      return if (delta_timing.blank? || delta_timing.zero?) && (lap_timing.blank? || lap_timing.zero?)

      # Discriminate parent in order to create proper (sub-)lap:
      if mr_model.is_a?(GogglesDb::MeetingIndividualResult)
        # *** MIR -> Lap ***
        Rails.logger.debug { "    >> Lap #{length_in_meters}m: <#{lap_timing}>" } if @toggle_debug
        lap_entity = find_or_prepare_lap(
          meeting_program:, mprogram_key:, swimmer:, swimmer_key:,
          team:, team_key:, mir: mr_model, mir_key: mr_key, length_in_meters:,
          abs_timing: lap_timing, # (abs = "from start")
          delta_timing: # (delta = "each individual lap")
        )
        lap_key = "lap#{length_in_meters}-#{mr_key}"
        return if entity_present?('lap', lap_key)

        add_entity_with_key('lap', lap_key, lap_entity)

      elsif mr_model.is_a?(GogglesDb::MeetingRelayResult)
        mrs_key = "mrs#{order}-#{mr_key}"
        # NOTE:
        # 1. always create MRS first so that the binding in the relay lap can be set
        # 2. restore MRS from cache when processing a relay lap (length < phase_length)
        # 3. always process MRS & sub-laps in crescent order so that previous lap timing is available

        # *** MRR -> MRS ("last sub-lap") ***
        Rails.logger.debug { "    >> Relay Swimmer '#{swimmer_key}' @ #{length_in_meters}m: <#{lap_timing}>" } if @toggle_debug
        mrs_entity = find_or_prepare_rel_swimmer(
          meeting_program:, mprogram_key:, event_type:,
          swimmer:, swimmer_key:, badge:,
          team:, team_key:, mrr: mr_model, mrr_key: mr_key,
          relay_order: order, length_in_meters:,
          abs_timing: lap_timing, # (abs = "from start")
          delta_timing: # (delta = "each individual lap")
        )
        # Add MRS only when missing:
        add_entity_with_key('meeting_relay_swimmer', mrs_key, mrs_entity) unless entity_present?('meeting_relay_swimmer', mrs_key)

      elsif mr_model.is_a?(GogglesDb::MeetingRelaySwimmer) && sub_phases.positive?
        mrr_key = mrr_key_for(mprogram_key, team_key)
        mrr_row = cached_instance_of('meeting_relay_result', mrr_key)

        # *** MRS -> RelayLap ***
        # (when length is enough and sub-laps are present)
        Rails.logger.debug { "    >> RelayLap #{length_in_meters}m: <#{lap_timing}>" } if @toggle_debug
        relay_lap_entity = find_or_prepare_relay_lap(
          swimmer:, swimmer_key:, team:, team_key:,
          mrr: mrr_row, mrr_key:,
          mrs: mr_model, mrs_key: mr_key,
          length_in_meters:,
          abs_timing: lap_timing, # (abs = "from start")
          delta_timing: # (delta = "each individual lap")
        )
        relay_lap_key = "relay_lap#{length_in_meters}-#{mr_key}"
        # Add RelayLap only when missing:
        add_entity_with_key('relay_lap', relay_lap_key, relay_lap_entity) unless entity_present?('relay_lap', relay_lap_key)

      else
        # *** UNSUPPORTED! ***
        # WARNING:
        # This may happen if any of the parent entities above didn't get created before handling the child lap here.
        # May be due to wrong sub-lap indexing or a lap timing for a relay that didn't get extracted.
        # Most of the times, the lap timing is missing from relays due to its DSQ status.
        # For "long relays" (4x100, 4x200), if the master lap associated with the MRS is missing its timing
        # (e.g., for a 4x100, anyone missing from these: lap100, lap200, lap300 or lap400) then the whole relay fraction
        # won't be stored at all. In these cases, ignore the 'pry' below as there's no point in debugging)
        Rails.logger.debug { "    >> INVALID PARAMETERS for lap timing extraction: target model #{mr_model.class}" } if @toggle_debug
        # DEBUG ----------------------------------------------------------------
        binding.pry
        # ----------------------------------------------------------------------
      end
      # Return current lap timing (can be used when processing next lap to compute any missing delta):
      lap_timing
    end
    #-- -----------------------------------------------------------------------
    #++

    # Finds or prepares the creation of a MeetingTeamScore row given all of the following parameters.
    #
    # == Params:
    # - <tt>:meeting</tt> => the parent Meeting instance (single, best candidate found or created)
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::Team instance
    # - <tt>:team_key</tt> => Team key in the entity sub-Hash stored at root level in the data Hash member
    #                         (may differ from the actual Team.name returned by a search)
    #
    # - <tt>:team_affiliation</tt> => associated TeamAffiliation
    # - <tt>:rank</tt> => integer ranking position
    # - <tt>:ind_score</tt> => Float score for "individual points" (using FIN scoring rules)
    # - <tt>:overall_score</tt> => Float score for "overall points" (using FIN scoring rules)
    #
    # == Returns:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    #
    def find_or_prepare_team_score(meeting:, team:, team_key:, team_affiliation:, rank:,
                                   ind_score: 0.0, overall_score: 0.0)
      bindings = { 'team_affiliation' => team_key, 'team' => team_key }
      domain = GogglesDb::MeetingTeamScore.where(
        meeting_id: meeting&.id,
        team_id: team&.id, team_affiliation_id: team_affiliation&.id
      )
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      new_row = GogglesDb::MeetingTeamScore.new(
        meeting_id: meeting&.id,
        season_id: @season&.id,
        team_id: team&.id,
        team_affiliation_id: team_affiliation&.id,
        rank:,
        sum_individual_points: ind_score,
        sum_relay_points: overall_score - ind_score,
        sum_team_points: overall_score,
        meeting_points: ind_score,
        meeting_relay_points: overall_score - ind_score,
        meeting_team_points: overall_score,
        season_points: 0.0, # (no data)
        season_relay_points: 0.0, # (no data)
        season_team_points: 0.0 # (no data)
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists
    #-- -----------------------------------------------------------------------
    #++

    # Search & returns the full string key for the specified model name; +nil+ if not found.
    # Support Regexps as keys or partial keys for a simple find/starts_with.
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'swimmer' for Swimmer)
    #
    # - <tt>key_or_regexp</tt>: use a Regexp for a #match or use a String for #starts_with?
    #
    # == Returns:
    # The first key found for the specified <tt>model_name</tt> matching <tt>key_or_regexp</tt>,
    # or +nil+ if not found.
    def search_key_for(model_name, key_or_regexp)
      if key_or_regexp.is_a?(Regexp)
        @data&.fetch(model_name, {})&.keys&.find { |key| key.to_s.match?(key_or_regexp) }
      else
        @data&.fetch(model_name, {})&.keys&.find { |key| key.to_s.starts_with?(key_or_regexp) }
      end
    end

    # Scans the cached @data for the specified <tt>model_name</tt> and replaces each binding key found
    # equal to <tt>old_key</tt> with <tt>new_key</tt> in <tt>target_binding</tt>.
    # All cached instances of <tt>model_name</tt> wil be scanned for a match in their bindings.
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'swimmer' for Swimmer)
    # - <tt>old_key</tt>: the original old string key to be replaced
    # - <tt>new_key</tt>: the new value of the string key for the replacement
    # - <tt>target_binding</tt>: the target binding to be modified
    #
    def replace_key_in_bindings_for(model_name, old_key, new_key, target_binding)
      @data[model_name]&.each_value do |cached_instance|
        bindings = if cached_instance.is_a?(Hash)
                     cached_instance['bindings']
                   elsif cached_instance.respond_to?(:bindings)
                     cached_instance.bindings
                   end
        next if bindings.blank?

        bindings[target_binding] = new_key if bindings[target_binding] == old_key
      end
    end

    # Getter for any model instance stored at root level (as edit/review cache) given a specific access key.
    # This method detects also if the cached row is inside an Hash (re-parsed JSON) or a not-yet serialized Import::Entity#row.
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'meeting_session' for MeetingSession)
    #
    # - <tt>key_name_or_index</tt>: access key (or index, for MeetingSessions) for the cached entity row;
    #                               ignored if the model is 'meeting' (there's only 1)
    #
    # - <tt>value_method</tt>: either 'row', 'bindings' or 'matches' to retrieve one of the possible serialized
    #                          members of the Import::Entity referenced by the model & key above.
    #
    # == Returns:
    # With the default parameters ('row'), this will be an ActiveRecord model created (or loaded) using the current data Hash values;
    # +nil+ in case of unsupported values or errors.
    #
    # Depending on the value of <tt>value_method</tt> this will yield:
    # - 'row' => the Model built from value row when found (or a new instance of it, created using the attributes found
    #            from the cached hash);
    # -'bindings' => the actual bindings Hash, "as is" (depeding whether the cached items are serialized or not);
    # -'matches' => the 'matches' Array, "as is" (as above: the serialization changes any structure to Array/Hash).
    #
    def cached_instance_of(model_name, key_name_or_index, value_method = 'row')
      return nil unless entity_present?(model_name, key_name_or_index)

      if model_name == 'meeting'
        return {} if value_method == 'bindings' # Meetings don't have bindings: we're done here

        cached_entity = @data&.fetch(model_name, nil)
      else
        cached_entity = @data&.fetch(model_name, nil)&.fetch(key_name_or_index, nil)
      end

      return cached_entity if cached_entity.is_a?(ActiveRecord::Base) # already a row model
      return cached_entity.send(value_method) if cached_entity.respond_to?(value_method) # kinda Import::Entity
      return cached_entity.fetch(value_method, []) if cached_entity.is_a?(Hash) && value_method == 'matches'
      return cached_entity.fetch(value_method, {}) if cached_entity.is_a?(Hash) && value_method == 'bindings'

      # At this point: cached_entity => Hash && requested 'row' => 'need to build a model from them:
      # For anything else, we return a new Model. 2 possibilities:
      # 1. hash of attributes keys by 'row'
      # 2. direct hash of attributes (from serialized model, no 'row' key)
      attr_hash = cached_entity&.fetch(value_method, nil).presence || cached_entity
      self.class.model_class_for(model_name).new(self.class.actual_attributes_for(attr_hash, model_name))
    end

    # Scans the cached entity Array or Hash given the specified root-level access key
    # (the <tt>model_name</tt>) and rebuilds the same structure.
    # (A plain Import::Entity for 'meeting' only; Array for 'meeting_session' only;
    #  an Hash for all the others)
    #
    # Assumes the corresponding entity for <tt>model_name</tt> has been already mapped or
    # serialized as JSON into the internal @data hash before calling this.
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'meeting_session' for MeetingSession)
    #
    # == Returns
    # the corresponding structure container for the corresponding Import::Entities.
    # +nil+ in case of errors.
    #
    def rebuild_cached_entities_for(model_name)
      if model_name == 'meeting' # plain Import::Entity(Meeting)
        return @data['meeting'] if @data['meeting'].is_a?(Import::Entity)

        # Convert all meeting matches from the fuzzy search into proper Model results:
        row_model, row_matches, row_bindings = prepare_model_matches_and_bindings_for('meeting', @data['meeting']['matches'], nil)
        return Import::Entity.new(row: row_model, matches: row_matches) # Ignore bindings
      end

      cached_data = @data&.fetch(model_name, nil)
      if model_name == 'meeting_session' # ARRAY of Import::Entity(MeetingSession)
        result = []
        # Rebuild the result structure:
        cached_data.each_with_index do |item, index|
          row_model, row_matches, row_bindings = prepare_model_matches_and_bindings_for('meeting_session', item, index)
          result[index] = Import::Entity.new(row: row_model, matches: row_matches, bindings: row_bindings)
        end
        # Overwrite existing with newly rebuilt:
      else # HASH of serialized Import::Entity(<model_name>)
        result = {}
        cached_data.each do |item_key, item|
          row_model, row_matches, row_bindings = prepare_model_matches_and_bindings_for(model_name, item, item_key)
          result[item_key] = Import::Entity.new(row: row_model, matches: row_matches, bindings: row_bindings)
        end
      end
      @data[model_name] = result.compact

      @data[model_name]
    end

    # Checks for the presence of a entity instance for a corresponding key inside a specific model_name "cache"
    # @data Hash.
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'meeting_session' for MeetingSession)
    #
    # - <tt>key_name_or_index</tt>: access key (or index, for MeetingSessions) for the cached entity row;
    #                               ignored if the model is 'meeting' (there's only 1)
    #
    # == Returns:
    # +false+ if the value row is missing, +true+ otherwise.
    #
    # This method will initialize the key with an empty sub-Hash when missing, for any other model name except
    # for 'meeting' & 'meeting_session' (since those 2 are always overwritten).
    #
    def entity_present?(model_name, key_name_or_index)
      return @data&.fetch('meeting', nil).present? if model_name == 'meeting'
      return @data&.fetch('meeting_session', nil)&.fetch(key_name_or_index, nil).present? if model_name == 'meeting_session'

      @data[model_name] ||= {}
      @data[model_name].fetch(key_name_or_index, nil).present?
    end

    # Adds the specified <tt>entity_value</tt> to the <tt>model_name</tt> data Hash, using <tt>key_name</tt>
    # as unique key; initializes the sub-Hash if still missing.
    # Any preexisting value will be overwritten. Works only for Hash-type cached entities.
    def add_entity_with_key(model_name, key_name, entity_value)
      @data[model_name] ||= {}
      @data[model_name][key_name] = entity_value
    end

    # Extracts and somehow "normalizes"/rebuilds the model, matches and bindings for a specific cached entity model,
    # given its key.
    #
    # == Example:
    #   > prepare_model_matches_and_bindings_for('team', team_hash, key_name_or_index)
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'meeting_session' for MeetingSession)
    #
    # - <tt>entity_or_hash</tt>: the cached Import::Entity for the specified (model, key) tuple.
    #                            It can also be an already converted Array of AR Models (the actual search items list).
    #
    # - <tt>key_name_or_index</tt>: access key (or index, for MeetingSessions) for the cached entity row;
    #                               ignored if the model is 'meeting' (there's only 1)
    #
    # == Returns:
    # An <tt>Array</tt> of 3 results:
    # - an actual row Model instance associated to the attributes stored for the <tt>model_name</tt> accessed
    #   using the specified key
    #
    # - an Array of alternative candidate model instances, obtained usually by a fuzzy search command
    #
    # - an Hash of bindings having the structure <tt>{ <model_name> => <key_name_or_index> }</tt>, pointing
    #   to the bound associated model instances stored in the cache.
    #   (i.e., for a MeetingSession: <tt>{ 'swimming_pool' => 'key_name_to_the_cached_row' }</tt>)
    #
    def prepare_model_matches_and_bindings_for(model_name, entity_or_hash, key_name_or_index)
      row_model = cached_instance_of(model_name, key_name_or_index)

      # Translate the original search result of Array of "matches" as a "plain" Array of model instances,
      # giving up the weights or the table/candidate structure in it (if present):
      orig_matches = if entity_or_hash.respond_to?(:matches)
                       entity_or_hash.matches
                     elsif entity_or_hash.is_a?(Hash)
                       entity_or_hash.fetch('matches', nil)
                     elsif entity_or_hash.is_a?(Array) # ASSUMES: it's already an Array of AR models
                       entity_or_hash
                     end
      row_matches = orig_matches&.map do |search_item|
        convert_search_item_to_model_for(model_name, row_model, search_item)
      end

      row_bindings = if entity_or_hash.respond_to?(:bindings)
                       entity_or_hash.bindings
                     elsif entity_or_hash.is_a?(Hash)
                       entity_or_hash.fetch('bindings', nil)
                     end

      [row_model, row_matches, row_bindings]
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts miscellaneous types of <tt>search_item</tt>s to a simple ActiveRecord Model
    # instance containing the same values as the original search item.
    #
    # === Reason:
    # Given the various types of query/fuzzy search results, any <tt>search_item</tt> can be an
    # Hash or any other resulting class from the finder strategies.
    # These are in turn serialized to JSON, so most of the times we'll deal with Hash results but with
    # varying columns and sub-hash structures, depeding at which stage this method is called.
    # (NOTE TO SELF: this is just a quick attempt at cleaning up and smoothe old code which aged pretty quickly
    #  due to unforeseen issues and surely needs a more profound refactoring in future)
    #
    # == Params:
    # - <tt>model_name</tt>: the snail-case string name of the model, with the implied GogglesDb namespace.
    #                        (i.e.: 'meeting_session' for MeetingSession)
    #
    # - <tt>row_model</tt>: "source" instance belonging to the above model
    #
    # - <tt>search_item</tt>: a matching search result, typically an Hash of attributes, to be converted
    #                         into the destination <tt>model_name</tt>.
    #                         It may also be a Struct/OpenStruct, an Import::Entity or a plain AR Model.
    #
    # == Returns:
    # A <tt>model_name</tt> instance having a the <tt>search_item</tt> values as column attributes.
    # May return the <tt>row_model</tt> only in peculiar cases.
    # (As of this writing, only if the search item is a Cities::City that needs to be converted to a GogglesDb::City.)
    #
    def convert_search_item_to_model_for(model_name, row_model, search_item)
      search_model = if search_item.is_a?(Hash) && search_item.key?('table') && search_item['table'].key?('candidate')
                       # Hash from already serialized Import::Entity search result (Hash['candidate'])
                       self.class.model_class_for(model_name).new(
                         self.class.actual_attributes_for(search_item['table']['candidate'], model_name)
                       )

                     elsif search_item.respond_to?(:candidate)
                       # original Struct/OpenStruct result (unserialized yet)
                       search_item.candidate

                     elsif search_item.is_a?(Hash) && search_item.fetch('data', nil).is_a?(Hash)
                       # single Hash in Array, but serialized from a Cities::City:
                       # (holds attributes under the 'data' subhash)
                       self.class.model_class_for(model_name).new(
                         self.class.actual_attributes_for(search_item['data'], model_name)
                       )

                     elsif search_item.is_a?(Hash)
                       # single Hash in Array (plain model already serialized):
                       self.class.model_class_for(model_name).new(
                         self.class.actual_attributes_for(search_item, model_name)
                       )

                     elsif search_item.is_a?(ActiveRecord::Base)
                       # plain Model in Array (no fuzzy search):
                       self.class.model_class_for(model_name).new(
                         self.class.actual_attributes_for(search_item.attributes, model_name)
                       )

                     elsif search_item.is_a?(Import::Entity) && search_item.respond_to?(:row)
                       # => ASSERT: UNEXPECTED OBJECT HERE (Import::Entity instance instead of Array[Hash] or [Hash])
                       # => RAISE ERROR & INSPECT search_item, which should be either be one of the 2 above
                       # raise "Unexpected Import::Entity after data_hash reconstruction! Possible data corruption!"
                       search_item.row

                     elsif search_item.is_a?(Cities::City) && row_model.is_a?(GogglesDb::City)
                       # No search alternatives, just a Cities::City returned from CmdFindIsoCity, so we may as well as return
                       # the row_model here as single match:
                       row_model
                     end

      # Return the decorated search model instance, but only for certain model names:
      %w[team swimmer city].include?(model_name) ? search_model.decorate : search_model
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the internal string key used to access a cached Swimmer entity row, or
    # a Regexp tailored to search for the actual key whenever the gender, the YOB or
    # even the team name are unknown.
    #
    # == Params
    # - <tt>swimmer_original_name</tt>: original swimmer name text extracted from the result file "as is"
    #   (not the full name from the matched model row);
    #
    # - <tt>year_of_birth</tt>: GogglesDb::Swimmer#year_of_birth;
    #
    # - <tt>gender_type_code</tt>: GogglesDb::GenderType#code for the swimmer;
    #   when +nil+ a Regexp for seeking the full key will be returned instead
    #   (so that it can be used with #cached_instance_of());
    #
    # - <tt>team_original_name</tt>: original team name text extracted from the result file "as is".
    #
    def swimmer_key_for(swimmer_original_name, year_of_birth, gender_type_code, team_original_name)
      if gender_type_code.blank? || year_of_birth.blank? || team_original_name.blank?
        search_exp = "#{swimmer_original_name}-"
        search_exp += "#{year_of_birth.presence || '\d{4}'}-"
        # If the team name is blank, being it the last part of the Regexp, it won't matter:
        search_exp += "#{gender_type_code.presence || '[MF]'}-#{team_original_name}"
        return search_key_for('swimmer', Regexp.new(search_exp, Regexp::IGNORECASE))
      end

      "#{swimmer_original_name}-#{year_of_birth}-#{gender_type_code}-#{team_original_name}"
    end

    # Returns the internal string key used to access a cached MeetingEvent entity row.
    #
    # == Params
    # - <tt>session_order</tt>: order of the meeting session (typically, session index + 1).
    # - <tt>event_type_code</tt>: GogglesDb::EventType#code for the event.
    #
    def event_key_for(session_order, event_type_code)
      # Use a fixed '1' as session number as long as we can't determine which is which:
      "#{session_order}-#{event_type_code}"
    end

    # Returns the internal string key used to access a cached MeetingProgram entity row.
    #
    # == Params
    # - <tt>event_key</tt>: string key used to access the cached entity row for the parent MeetingEvent;
    # - <tt>category_type_code</tt>: GogglesDb::CategoryType#code for the program;
    # - <tt>gender_type_code</tt>: GogglesDb::GenderType#code for the program.
    #
    def program_key_for(event_key, category_type_code, gender_type_code)
      "#{event_key}-#{category_type_code}-#{gender_type_code}"
    end

    # Returns the internal string key used to access a cached MeetingIndividualResult entity row.
    #
    # == Params
    # - <tt>program_key</tt>: string key used to access the cached entity row for the parent MeetingProgram;
    # - <tt>swimmer_key</tt>: as above, but for the associated GogglesDb::Swimmer.
    def mir_key_for(program_key, swimmer_key)
      "#{program_key}/#{swimmer_key}"
    end

    # Returns the internal string key used to access a cached MeetingRelayResult entity row.
    #
    # == Params
    # - <tt>program_key</tt>: string key used to access the cached entity row for the parent MeetingProgram;
    # - <tt>team_key</tt>: as above, but for the associated GogglesDb::Team.
    def mrr_key_for(program_key, team_key)
      "#{program_key}/#{team_key}"
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # Prepares the Team model given the specified data or simply returns it if
    # it has been already mapped.
    #
    # == Options:
    # - <tt>:team_key</tt> => string key used to ID the +team+ entity in cache
    #
    # == Returns:
    # The mapped Team model row.
    #
    def map_and_return_team(team_key:)
      # Add only if not already present in hash:
      return cached_instance_of('team', team_key) if entity_present?('team', team_key)

      Rails.logger.debug { "\r\n\r\n*** TEAM '#{team_key}' (+) ***" } if @toggle_debug
      team_entity = find_or_prepare_team(team_key)
      team_entity.add_bindings!('team_affiliation' => team_key)
      add_entity_with_key('team', team_key, team_entity)
      team_entity.row
    end

    # Assuming there's an existing MIR associated to the specified swimmers parameter,
    # this method will behave more or less similarly to #map_and_return_team(team_key:).
    #
    # The currently cached Meeting instance will be used to find the MIR by seeking the Swimmer first.
    # Whenever a matching MIR is found, the corresponding Team will be mapped as an entity inside
    # the list and returned as a row model.
    #
    # This will only work if there's an existing meeting with a matching MIR for the specified
    # swimmer: no mapping of the Team will occur if there's no pre-existing MIR.
    #
    # == Params:
    # - <tt>swimmer_name</tt> => name of the swimmer
    # - <tt>year_of_birth</tt> => YOB of the swimmer
    #
    # == Returns:
    # The mapped Team model row when a matching MIR is found; +nil+ otherwise.
    #
    def map_and_return_team_from_matching_mir(swimmer_name, year_of_birth, sex_code)
      meeting = cached_instance_of('meeting', nil)
      if meeting.id.blank?
        Rails.logger.warn('Team name MISSING while the Meeting is new: unable to find an existing associated MIR!')
        return
      end

      swimmer_entity = find_or_prepare_swimmer(swimmer_name, year_of_birth, sex_code)
      return if swimmer_entity.blank?

      mir = GogglesDb::MeetingIndividualResult.includes(:meeting)
                                              .where(swimmer_id: swimmer_entity.row.id, 'meetings.id': meeting.id)
                                              .first
      return unless mir&.team

      team_entity = Import::Entity.new(row: mir.team, matches: [mir.team])
      team_entity.add_bindings!('team_affiliation' => mir.team.name)
      add_entity_with_key('team', mir.team.name, team_entity)
      team_entity.row
    end

    # Prepares the TeamAffiliation model given the specified data or simply returns it if
    # it has been already mapped.
    #
    # == Options:
    # - <tt>:team</tt> => the Team model row associated to the TeamAffiliation
    # - <tt>:team_key</tt> => string key used to ID the +team+/+team_affiliation+ entity in cache
    #
    # == Returns:
    # The mapped TeamAffiliation model row.
    #
    def map_and_return_team_affiliation(team:, team_key:)
      return cached_instance_of('team_affiliation', team_key) if entity_present?('team_affiliation', team_key)

      team_affiliation_entity = find_or_prepare_affiliation(team, team_key, @season)
      team_affiliation_entity.add_bindings!('team' => team_key)
      add_entity_with_key('team_affiliation', team_key, team_affiliation_entity)
      team_affiliation_entity.row
    end

    # Prepares the swimmer key and its associated model given the specified data or simply
    # returns the already mapped model if there is one.
    #
    # == Options:
    # - <tt>:swimmer_name</tt> => swimmer's full name;
    # - <tt>:year_of_birth</tt> => swimmer's year of birth;
    #
    # - <tt>:gender_type_code</tt> => swimmer's gender code ('M', 'F', 'X'); leave
    #   default +nil+ if unknown (a partial key search will be performed);
    #
    # - <tt>:team_name</tt> => swimmer's team name.
    #
    # == Returns:
    # The tuple [<swimmer_key>, <swimmer_model>] or [nil, nil] in case of errors.
    #
    def map_and_return_swimmer(options = {})
      swimmer_key = swimmer_key_for(options[:swimmer_name], options[:year_of_birth],
                                    options[:gender_type_code], options[:team_name])
      # NOTE: swimmer_key may result nil when the swimmer isn't already present as a parsed entity
      #       and some of its fields are unknown - which will yield a key search among
      #       the ones already existing. (An additional DB search could address that, assuming the row is in the DB)
      return [swimmer_key, cached_instance_of('swimmer', swimmer_key)] if entity_present?('swimmer', swimmer_key)

      # The following can happen for swimmers that enrolled just in relays, with a result
      # format missing some of the data:
      if options[:gender_type_code].blank?
        Rails.logger
             .warn("\r\n    ------> '#{options[:swimmer_name]}' *** SWIMMER WITH MISSING gender_type_code (probably from a relay)")
      end
      if options[:year_of_birth].blank?
        Rails.logger
             .warn("\r\n    ------> '#{options[:swimmer_name]}' *** SWIMMER WITH MISSING year_of_birth (probably from a relay)")
      end

      Rails.logger.debug { "\r\n=== SWIMMER '#{options[:swimmer_name]}' (+) ===" } if @toggle_debug
      swimmer_entity = find_or_prepare_swimmer(options[:swimmer_name], options[:year_of_birth],
                                               options[:gender_type_code])
      raise 'Cannot store a nil swimmer entity!' if swimmer_entity.blank?

      # Rebuild the key from the resulting entity in case the search nullified the partial key:
      if swimmer_key.blank?
        swimmer_key = swimmer_key_for(options[:swimmer_name], swimmer_entity.row.year_of_birth,
                                      swimmer_entity.row.gender_type.code, options[:team_name])
      end
      # Special disambiguation reference (in case of same-named swimmers with same age):
      swimmer_entity&.add_bindings!('team' => options[:team_name])
      # Store the required bindings at root level in the data_hash:
      # (ASSERT: NEVER store entities with blank or partial keys)
      raise 'Cannot store a swimmer with a blank or partial key!' if swimmer_key.blank?

      add_entity_with_key('swimmer', swimmer_key, swimmer_entity)
      # Return both the key and its mapped model row:
      [swimmer_key, swimmer_entity.row]
    end

    # Prepares the badge model given the specified data or simply
    # returns the already mapped model if there is one.
    #
    # == Options:
    # - <tt>:swimmer</tt> => a valid or new GogglesDb::Swimmer instance
    # - <tt>:swimmer_key</tt> => string key used to ID the +swimmer+ entity above in cache
    #
    # - <tt>:team</tt> => a valid or new GogglesDb::Team instance
    # - <tt>:team_key</tt> => string key used to ID the +team+ entity above in cache
    #
    # - <tt>:team_affiliation</tt> => a valid or new GogglesDb::TeamAffiliation instance
    # - <tt>:category_type</tt> => a valid GogglesDb::CategoryType instance
    # - <tt>:badge_code</tt> => a 40-char string representing the badge number or code
    #
    # == Returns:
    # The mapped badge model row.
    #
    def map_and_return_badge(options = {})
      return cached_instance_of('badge', options[:swimmer_key]) if entity_present?('badge', options[:swimmer_key])

      # Make sure we don't assign badges using relay category types by mistake:
      category_type = if options[:category_type].blank? || options[:category_type]&.relay?
                        post_compute_ind_category_code(options[:swimmer].year_of_birth)
                      else
                        options[:category_type]
                      end
      badge_entity = find_or_prepare_badge(
        swimmer: options[:swimmer], swimmer_key: options[:swimmer_key],
        team: options[:team], team_key: options[:team_key],
        team_affiliation: options[:team_affiliation],
        category_type:,
        badge_code: options[:badge_code]
      )
      add_entity_with_key('badge', options[:swimmer_key], badge_entity)
      badge_entity.add_bindings!('swimmer' => options[:swimmer_key])
      badge_entity.add_bindings!('team' => options[:team_key])
      Rails.logger.debug { "    ------> BADGE '#{swimmer_name}' (+)" } if @toggle_debug
      badge_entity.row
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans the content of the specified row Hash (assuming it contains data stored
    # using our "L2" format), verifies it contains result from an INDIVIDUAL result (including
    # Lap data), and makes sure each entity is already mapped and present inside the Entity cache.
    # (If a required entity is already mapped and present in cache, the corresponding
    # Import::Entity instance won't be added.)
    #
    # If the full options for processing also the MIR as a result are given,
    # lap timings will be extracted & mapped as well.
    #
    # Each option outlines a part of the +row+ data that has been already processed.
    #
    # == Required options:
    # - <tt>:row</tt>: a "L2" hash result row, allegedly from a MIR (it should NOT contain
    #                  the 'relay' boolean flag in it), wrapping the data to be processed.
    #
    # - <tt>:category_type</tt> => a valid GogglesDb::CategoryType instance
    # - <tt>:event_type</tt> => a valid GogglesDb::EventType instance
    #
    # == Additional options:
    # If any of these are missing, the method will skip the extraction of the
    # lap timings and the subsequent creation of the associated Lap entities.
    #
    # - <tt>:mprg</tt> => a valid or new GogglesDb::MeetingProgram instance
    # - <tt>:mprg_key</tt> => string key used to ID the +mprg+ entity above in cache
    #
    def process_mir_and_laps(options = {})
      return unless options[:row].is_a?(Hash) && options[:row]['relay'].blank?

      row = options[:row]
      team_name = row['team']
      swimmer_name = row['name']
      year_of_birth = row['year']
      gender_type_code = row['sex']
      badge_code = "#{row['badge_region']}-#{row['badge_num']}" if row['badge_region'].present? && row['badge_num'].present?
      # (Gender code can also be retrieved by search, if missing)
      # Skip processing if we weren't able to set the team name before,
      # during the "map_teams_and_swimmers" phase:
      Rails.logger.warn("Unrecoverable null team name for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code}): skipping result.") if team_name.blank?
      return unless team_name.present? && swimmer_name.present? && year_of_birth.present?

      team = map_and_return_team(team_key: team_name)
      # This should never occur at this point (unless data is corrupted):
      raise("No team ENTITY for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code})!") if team.blank?

      team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
      swimmer_key, swimmer = map_and_return_swimmer(swimmer_name:, year_of_birth:, gender_type_code:,
                                                    team_name:)
      # NOTE: 2: #map_and_return_badge will handle nil or relay category types with #post_compute_ind_category_code(YOB)
      badge = map_and_return_badge(swimmer:, swimmer_key:, team:, team_key: team_name,
                                   team_affiliation:, category_type: options[:category_type],
                                   badge_code:)
      # This should never occur at this point (unless data is corrupted):
      if team_affiliation.blank? || badge.blank? || swimmer.blank?
        raise("No team_affiliation, badge, or swimmer ENTITY for '#{swimmer_name}' (#{year_of_birth}, #{gender_type_code})!")
      end
      return unless options[:mprg].present? && options[:mprg_key].present? && options[:event_type].present?

      rank = row['pos'].to_i
      score = Parser::Score.from_l2_result(row['score'])
      timing = Parser::Timing.from_l2_result(row['timing'])
      mir_key = mir_key_for(options[:mprg_key], swimmer_key)
      # NOTE: MIR already mapped => laps won't be processed
      return if entity_present?('meeting_individual_result', mir_key)

      mir_entity = find_or_prepare_mir(
        meeting_program: options[:mprg], mprogram_key: options[:mprg_key],
        swimmer:, swimmer_key:, team:, team_key: team_name,
        team_affiliation:, badge:,
        rank:, timing:, score:, disqualify_type: row['disqualify_type']
      )
      add_entity_with_key('meeting_individual_result', mir_key, mir_entity)
      mr_model = mir_entity.row

      # *** LAPS ***
      # Search and prepare Laps only when present, one instance for each possible 50m lap,
      # EXCLUDING LAST LAP (since we already use MIR's final timing as last lap result
      # and last delta timing is computed by Main's Lap table view component):
      lap_timing = Timing.new # (lap number zero)
      max_order = (options[:event_type].length_in_meters.to_i / 50)
      (1..(max_order - 1)).each do |lap_idx|
        lap_timing = extract_lap_timing_for(
          meeting_program: options[:mprg], mprogram_key: options[:mprg_key],
          event_type: options[:event_type],
          swimmer:, swimmer_key:, badge:, team:, team_key: team_name,
          mr_model:, mr_key: mir_key, order: lap_idx, max_order:,
          length_in_meters: lap_idx * 50, row:,
          prev_lap_timing: lap_timing
        )
      end
    end

    # Scans the content of the specified row Hash (assuming it contains data stored
    # using our "L2" format), verifies it contains result from a team RELAY RESULT (including
    # swimmer/lap data), and makes sure each entity is already mapped and present inside the Entity cache.
    # (If a required entity is already mapped and present in cache, the corresponding
    # Import::Entity instance won't be added.)
    #
    # If the full options for processing also the MRR as a result are given,
    # lap timings & swimmers will be extracted & mapped as well.
    #
    # Each option outlines a part of the +row+ data that has been already processed.
    #
    # == Required options:
    # - <tt>:row</tt>: a "L2" hash result row, allegedly from a MRR (it must have
    #                  the 'relay' boolean flag in it), wrapping the data to be processed.
    #
    # - <tt>:category_type</tt> => a valid GogglesDb::CategoryType instance (for the MRR, NOT for the MRS's badges)
    # - <tt>:event_type</tt> => a valid GogglesDb::EventType instance
    #
    # == Additional options:
    # If any of these are missing, the method will skip the extraction of the
    # lap timings and the subsequent creation of the associated MeetingRelaySwimmer entities.
    #
    # - <tt>:mprg</tt> => a valid or new GogglesDb::MeetingProgram instance
    # - <tt>:mprg_key</tt> => string key used to ID the +mprg+ entity above in cache
    #
    def process_mrr_and_mrs(options = {})
      return unless options[:row].is_a?(Hash) && options[:row]['relay'].present?

      row = options[:row]
      team_name = row['team']
      rank = row['pos'].to_i
      event_type = options[:event_type]
      score = Parser::Score.from_l2_result(row['score'])
      timing = Parser::Timing.from_l2_result(row['timing'])
      mrr_key = mrr_key_for(options[:mprg_key], team_name)
      # NOTE: MRR already mapped => MRswimmers won't be processed
      return if entity_present?('meeting_relay_result', mrr_key)

      team = map_and_return_team(team_key: team_name)
      team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
      # This should never occur at this point (unless data is corrupted):
      raise("No team or team_affiliation ENTITY for '#{team_name}'!") if team.blank? || team_affiliation.blank?
      return unless options[:mprg].present? && options[:mprg_key].present?

      mrr_entity = find_or_prepare_mrr(
        meeting_program: options[:mprg], mprogram_key: options[:mprg_key],
        team:, team_key: team_name, team_affiliation:, rank:,
        timing:, score:, disqualify_type: row['disqualify_type']
      )
      add_entity_with_key('meeting_relay_result', mrr_key, mrr_entity)
      mr_model = mrr_entity.row
      prev_lap_timing = Timing.new # (lap number zero)

      (1..event_type.phases).each do |phase_idx|
        swimmer_name = row["swimmer#{phase_idx}"]
        year_of_birth = row["year_of_birth#{phase_idx}"]
        gender_type_code = row["gender_type#{phase_idx}"] # (May be often nil)

        # Move to the next lap group if the relay swimmer is missing (DSQ relays)
        # NOTE: this will loose all data regarding laps for DSQ relays but, currently,
        #       the DB structure requires both MRR & MRS to be present for sub-laps to be created.
        # NOTE 2: year_of_birth & gender_type_code can be searched from already extracted data when missing
        next if swimmer_name.blank?

        swimmer_key, swimmer = map_and_return_swimmer(swimmer_name:, year_of_birth:, gender_type_code:, team_name:)
        # NOTE: usually badge numbers won't be added to relay swimmers due to limited space,
        #       so we revert to the default value (nil => '?')
        # NOTE 2: #map_and_return_badge will handle nil or relay category types with #post_compute_ind_category_code(YOB)
        badge = map_and_return_badge(swimmer:, swimmer_key:, team:, team_key: team_name,
                                     team_affiliation:, category_type: nil) # (nil => force badge retrieval when existing or "esteem category by YOB")
        # *** MRS (parent) ***
        prev_lap_timing = extract_lap_timing_for(
          meeting_program: options[:mprg], mprogram_key: options[:mprg_key],
          event_type:, swimmer:, swimmer_key:, badge:, team:, team_key: team_name,
          mr_model:, mr_key: mrr_key,
          order: phase_idx, # Actual relay phase
          max_order: event_type.phases,
          length_in_meters: phase_idx * event_type.phase_length_in_meters.to_i,
          row:,
          # Sometimes previous lap timing is missing from captured data,
          # so here we'll rely on the resulting computed value:
          prev_lap_timing:
        )
        mrs_key = "mrs#{phase_idx}-#{mrr_key}"
        mrs_row = cached_instance_of('meeting_relay_swimmer', mrs_key)

        # *** RelayLaps (siblings) ***
        # For long relays, support sub-laps in additional entities where the MRS will always
        # store the overall phase timing with its swimmer data:
        tot_sub_phases = event_type.phase_length_in_meters.to_i / 50
        sub_phases = tot_sub_phases - 1
        # Make it so that the parent MRS is always the last "sub-lap" of the group,
        # if there are other sub-laps to be added:
        sub_order_start = (phase_idx - 1) * (sub_phases + 1)

        # Example phase groups & indexes processing sub-laps for a 4x200m:
        #
        # Sub-lengths in groups:
        # (1..4).map { |i| (1..(200 / 50 - 1)).map {|j| ((i-1) * 200) + j * 50} }
        #
        # Sub-indexes in groups (actually used below to compute orders and lap lengths):
        # (1..4).map { |i| (1..(200 / 50 - 1)).map {|j| ((i-1) * 4) + j} } # => indexes
        # => [[1, 2, 3], [5, 6, 7], [9, 10, 11], [13, 14, 15]] # *50 => lengths
        # => [[50, 100, 150], [250, 300, 350], [450, 500, 550], [650, 700, 750]]
        #
        # Note that 200, 400, 600 & 800 need to be run before the sub-lap loop so that
        # the MRS entities associated with those can be cached before their sibling
        # sub-laps get processed.
        #
        # Nested loops in variables:
        #   (1..event_type.phases) --> (1..(event_type.phase_length_in_meters.to_i / 50 - 1))

        (1..sub_phases).each do |sublap_index|
          sub_order = sub_order_start + sublap_index
          extract_lap_timing_for(
            meeting_program: options[:mprg], mprogram_key: options[:mprg_key],
            event_type:, swimmer:, swimmer_key:, badge:, team:, team_key: team_name,
            mr_model: mrs_row, mr_key: mrs_key,
            order: phase_idx, # Actual relay phase
            max_order: event_type.phases,
            length_in_meters: sub_order * 50, # (ASSUME sub-laps will never diverge from 50mt)
            row:,
            prev_lap_timing: nil, # (we'll rely on captured data for this)
            sublap_index:, sub_phases:
          )
        end
      end
    end
    #-- -------------------------------------------------------------------------
    #++

    # Similarly to #process_mrr_and_mrs(), this simplified version of the same method
    # pre-parses a row containing relay data and possibly all its laps/swimmers,
    # in order to detect which gender code use. (So it's useful when the gender is
    # not specified in the meeting program section.)
    #
    # This will be successful only if all relay swimmers are included in the single data row
    # and these can found on the database or have already been mapped.
    #
    # == NOTE:
    # No actual MRR or MRS caching/mapping will be done here: the only entities that
    # will be mapped if not already are:
    #
    # - Team & TeamAffiliation
    # - Swimmers & Badges
    #
    # == Required options:
    # - <tt>:row</tt>: a "L2" hash result row, allegedly from a MRR (it must have
    #                  the 'relay' boolean flag in it), wrapping the data to be processed.
    #
    # - <tt>:category_type</tt> => a valid GogglesDb::CategoryType instance
    #
    # == Returns
    # The actual GogglesDb::GenderType instance detected by looking at the swimmers
    # forming the relay or +nil+ in case of errors or when not found at all.
    # (The latter may happen for DSQ relays which usually don't have any swimmers enlisted
    # as result rows.)
    #
    def preprocess_mrr_for_gender_code(options = {})
      return unless options[:row].is_a?(Hash) && options[:row]['relay'].present?

      team_name = options[:row]['team']
      team = map_and_return_team(team_key: team_name)
      team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
      # DEBUG: ******************************************************************
      # SHOULD NEVER HAPPEN at this point:
      binding.pry if team.nil? || team_affiliation.nil?
      # DEBUG: ******************************************************************

      gender_ids = []
      (1..MAX_SWIMMERS_X_RELAY).each do |swimmer_idx|
        swimmer_name = options[:row]["swimmer#{swimmer_idx}"]
        year_of_birth = options[:row]["year_of_birth#{swimmer_idx}"]
        gender_type_code = options[:row]["gender_type#{swimmer_idx}"] # (May be often nil)
        next unless swimmer_name.present? && year_of_birth.present?

        swimmer_key, swimmer = map_and_return_swimmer(swimmer_name:, year_of_birth:, gender_type_code:, team_name:)
        # NOTE: usually badge numbers won't be added to relay swimmers due to limited space,
        #       so we revert to the default value (nil => '?')
        # NOTE 2: #map_and_return_badge will handle nil or relay category types with #post_compute_ind_category_code(YOB)
        map_and_return_badge(swimmer:, swimmer_key:, team:, team_key: team_name,
                             team_affiliation:, category_type: nil) # (nil => force badge retrieval or compute category by YOB)
        # DEBUG: ******************************************************************
        # SHOULD NEVER HAPPEN at this point:
        binding.pry unless swimmer.present? && swimmer_key.present?
        # DEBUG: ******************************************************************
        gender_ids << swimmer.gender_type_id
      end
      # Return gender type as detected from the enrolled swimmers:
      # (Assuming all swimmers were included in data & properly detected)
      gender_ids = gender_ids.compact.uniq
      return if gender_ids.blank?

      gender_ids.count > 1 ? GogglesDb::GenderType.intermixed : GogglesDb::GenderType.find(gender_ids.first)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans the content of the specified rows array (assuming each element contains a
    # ranking Hash in "L2" format), verifies it contains proper ranking data
    # and makes sure each entity is already mapped and present inside the Entity cache.
    # (If a required entity is already mapped and present in cache, the corresponding
    # Import::Entity instance won't be added.)
    #
    # == Required options:
    # - <tt>:rows</tt>: the full array of ranking rows Hash in "L2" format.
    #                   (the parent section should contain the 'ranking' flag)
    #
    # - <tt>:meeting</tt> => the parent GogglesDb::Meeting instance
    #
    def process_team_score(rows:, meeting:)
      return unless rows.is_a?(Array) && meeting.is_a?(GogglesDb::Meeting)

      rows.each do |ranking_hash|
        next unless ranking_hash.is_a?(Hash) && ranking_hash['team'].present?

        team_name = ranking_hash['team']
        team = map_and_return_team(team_key: team_name)
        team_affiliation = map_and_return_team_affiliation(team:, team_key: team_name)
        # DEBUG: ******************************************************************
        # SHOULD NEVER HAPPEN at this point:
        binding.pry unless team.present? && team_affiliation.present?
        # DEBUG: ******************************************************************

        rank = ranking_hash['pos'].to_i
        ts_key = "#{rank}-#{team_name}"
        next if entity_present?('meeting_team_score', ts_key)

        ind_score = Parser::Score.from_l2_result(ranking_hash['ind_score'])
        overall_score = Parser::Score.from_l2_result(ranking_hash['overall_score'])

        ts_entity = find_or_prepare_team_score(
          meeting:, team:, team_key: team_name, team_affiliation:,
          rank:, ind_score:, overall_score:
        )
        add_entity_with_key('meeting_team_score', ts_key, ts_entity)
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts "generic" text categories "Axx" to "Mxx" or "Uxx", depending on what's
    # defined inside the current season. Uses the @categories_cache.
    # "category_label" should have the format "[AMU]dd".
    #
    # Uses the internal @categories_cache.
    # Returns a corresponding CategoryType instance when found or nil otherwise.
    #
    # == NOTE:
    # *DOESN'T WORK FOR RELAYS*
    #
    def detect_ind_category_from_code(category_label)
      lowest_cat = @categories_cache.key?('U20') ? 'U20' : 'U25'
      cat_code = category_label.gsub(/a/i, 'M')
      @categories_cache.key?(cat_code) ? @categories_cache[cat_code] : @categories_cache[lowest_cat]
    end

    # Detects the possible valid individual result category code given the year_of_birth of the swimmer.
    # Returns the string category code ("M<nn>") or +nil+ when not found.
    #
    # == Params:
    # - year_of_birth: year_of_birth of the swimmer as integer
    #
    # == NOTE:
    # Same implementation as L2Converter's helper but returns the actual CategoryType instead of just the code.
    #
    def post_compute_ind_category_code(year_of_birth)
      return unless year_of_birth.positive?

      age = @season.begin_date.year - year_of_birth
      _curr_cat_code, category_type = @categories_cache.find { |_c, cat| !cat.relay? && (cat.age_begin..cat.age_end).cover?(age) && !cat.undivided? }
      category_type
    end

    # Searches for "incomplete" swimmer keys (the specified key string minus the team_name)
    # in the @data hash and runs through every reference of it (mostly in bindings),
    # replacing them with the correct, full, swimmer_key (the actual value specified as parameter).
    # Does nothing if the team_name is blank or no data is present.
    #
    # == Params:
    # - swimmer_key: the full string key for accessing the Swimmer entity in the @data hash
    #                (meaning the actual full swimmer_key, including its proper team_name)
    # - team_name: the string team name part of the key, allegedly missing from incomplete references.
    #
    def update_partial_swimmer_key(swimmer_key, team_name)
      return if team_name.blank? || @data.blank? || @data['swimmer'].blank?

      partial_key = swimmer_key.gsub(team_name, '')
      # Determine whether we have to substitute the value from the partial key or the new one:
      cached_entity = if entity_present?('swimmer', swimmer_key)
                        @data['swimmer'][partial_key]
                      elsif entity_present?('swimmer', partial_key)
                        @data['swimmer'][swimmer_key]
                      end
      # Bail out if the entity has not been mapped at all yet:
      return if cached_entity.blank?

      # Remap or make sure the correct cached value is keyed by the full key:
      @data['swimmer'][swimmer_key] = cached_entity
      @data['swimmer'].delete(partial_key) if entity_present?('swimmer', partial_key)

      # For each linked entity, search its bindings for a reference to the partial key:
      replace_key_in_bindings_for('badge', partial_key, swimmer_key, 'swimmer')
      replace_key_in_bindings_for('meeting_individual_result', partial_key, swimmer_key, 'swimmer')
      replace_key_in_bindings_for('lap', partial_key, swimmer_key, 'swimmer')
      replace_key_in_bindings_for('meeting_relay_swimmer', partial_key, swimmer_key, 'swimmer')
      replace_key_in_bindings_for('relay_lap', partial_key, swimmer_key, 'swimmer')
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
end
