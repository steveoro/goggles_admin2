# frozen_string_literal: true

module Import
  #
  # = MacroSolver
  #
  #   - version:  7-0.5.02
  #   - author:   Steve A.
  #   - build:    20230424
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

    # 1-pass solver wrapping the 3 individual steps (meeting & sessions; teams & swimmers; events & results).
    # Updates the source @data with serializable DB entities.
    # Currently, used for debugging purposes only.
    def solve
      map_meeting_and_sessions
      map_teams_and_swimmers
      map_events_and_results
      # TODO/FUTUREDEV: meeting scores & rankings for each team (currently: no data available)
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
      if meeting && meeting.id.present? && meeting.meeting_sessions.count.positive?
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
        end
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
      @data['meeting_session'] = [session1, session2]
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
    def map_teams_and_swimmers
      # Clear the lists:
      @data['team'] = {}
      @data['team_affiliation'] = {}
      @data['swimmer'] = {}
      @data['badge'] = {}
      total = @data['sections'].count
      idx = 0

      @data['sections'].each do |sect|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: 'map_teams_and_swimmers', progress: idx, total:)
        # If the section contains a 'retry' subsection it means the crawler received some error response during
        # the data crawl and the result file is missing the whole result subsection.
        next if sect['retry'].present?

        sect['rows'].each do |row|
          team_name = row['team']
          Rails.logger.debug { "\r\n\r\n*** TEAM '#{team_name}' ***" } if @toggle_debug
          # Add only if not already present in hash:
          unless entity_present?('team', team_name)
            Rails.logger.debug { "    ---> '#{team_name}' (+)" } if @toggle_debug
            team_entity = find_or_prepare_team(team_name)
            # Convenience reference for this meeting:
            team_entity.add_bindings!('team_affiliation' => team_name)
            # Store required bindings at root level in data_hash, same key, different entity:
            add_entity_with_key('team', team_name, team_entity)
          end

          swimmer_name = row['name']
          Rails.logger.debug { "\r\n=== SWIMMER '#{swimmer_name}' ===" } if @toggle_debug
          year_of_birth = row['year']
          gender_type_code = row['sex']
          swimmer_key = swimmer_key_for(swimmer_name, year_of_birth, gender_type_code, team_name)
          next if entity_present?('swimmer', swimmer_key)

          Rails.logger.debug { "    ------> '#{swimmer_name}' (+)" } if @toggle_debug
          swimmer_entity = find_or_prepare_swimmer(swimmer_name, year_of_birth, gender_type_code)
          # Special disambiguation reference (in case of same-named swimmers with same age):
          swimmer_entity.add_bindings!('team' => team_name)
          # Store the required bindings at root level in the data_hash:
          add_entity_with_key('swimmer', swimmer_key, swimmer_entity)
        end
      end
    end

    # Mapper and setter for the list of unique events & results.
    #
    # == Resets & recomputes:
    # - @data['meeting_event'] => the Hash of (unique) Import::Entity-wrapped MeetingEvents.
    # - @data['meeting_program'] => the Hash of (unique) Import::Entity-wrappedMeetingPrograms.
    # - @data['meeting_individual_result'] => the Hash of (unique) Import::Entity-wrapped MeetingIndividualResults.
    # - @data['meeting_relay_result'] => the Hash of (unique) Import::Entity-wrapped MeetingRelayResults. (FUTUREDEV)
    #
    # == Note:
    # Currently, no data about the actual session in which the event was performed is provided:
    # all events (& programs) are forcibly assigned to just the first Meeting session found.
    # (Actual session information is usually available only on the Meeting manifest page.)
    #
    # FUTUREDEV: obtain manifest + parse it to get the actual session information.
    # FUTUREDEV: relay results (currently: no data available)
    #
    # rubocop:disable Metrics/BlockLength
    def map_events_and_results
      # Clear the lists:
      @data['meeting_event'] = {}
      @data['meeting_program'] = {}
      @data['meeting_individual_result'] = {}
      total = @data['sections'].count
      idx = 0

      meeting = cached_instance_of('meeting', nil)
      msession_idx = 0 # TODO: find a way to change session number (only in manifest?)
      event_order = 0
      program_order = 0
      meeting_session = cached_instance_of('meeting_session', msession_idx)

      # Map programs & events:
      @data['sections'].each_with_index do |sect, _sect_idx|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: 'map_events_and_results', progress: idx, total:)
        # If the section contains a 'retry' subsection it means the crawler received some error response during
        # the data crawl and the result file is missing the whole result subsection.
        next if sect['retry'].present?

        # (Example section 'title': "50 Stile Libero - M25")
        event_type, category_type = Parser::EventType.from_l2_result(sect['title'], @season)
        gender_type = select_gender_type(sect['fin_sesso'])
        event_key = event_key_for(event_type.code)
        program_key = program_key_for(event_key, category_type.code, gender_type.code)

        # == MeetingEvent: find/create unless key is present (stores just the first unique key found):
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

        # == MeetingProgram: find/create unless key is present (as above):
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
        sect['rows']&.each_with_index do |row, _row_idx|
          # == MeetingIndividualResult: find/create unless key is present (as above):
          team_name = row['team']
          swimmer_name = row['name']
          team = cached_instance_of('team', team_name)

          # Find or prepare team affiliation for the team:
          unless entity_present?('team_affiliation', team_name)
            team_affiliation_entity = find_or_prepare_affiliation(team, team_name, @season)
            add_entity_with_key('team_affiliation', team_name, team_affiliation_entity)
          end

          team_affiliation = cached_instance_of('team_affiliation', team_name)
          year_of_birth = row['year']
          gender_type_code = row['sex']
          swimmer_key = swimmer_key_for(swimmer_name, year_of_birth, gender_type_code, team_name)
          swimmer = cached_instance_of('swimmer', swimmer_key)
          meeting_program = cached_instance_of('meeting_program', program_key)

          # Detect if team + swimmer mapping has been skipped and force-run it:
          # (This shall happen only once per loop if this method has been called *before* mapping teams or swimmers)
          if (team_name.present? && (team.nil? || team_affiliation.nil?)) ||
             (swimmer_name.present? && swimmer.nil?) || category_type.nil? || gender_type.nil?
            map_teams_and_swimmers
            # Reload instances after mapping:
            team = cached_instance_of('team', team_name)
            team_affiliation = cached_instance_of('team_affiliation', team_name)
            swimmer = cached_instance_of('swimmer', swimmer_key) # (Assumes swimmer_key is never empty)
            # DEBUG: ******************************************************************
            # binding.pry if team.nil? || team_affiliation.nil? || swimmer.nil? # SHOULD NEVER HAPPEN
            # DEBUG: ******************************************************************
          end

          # Find or prepare badge for the swimmer:
          unless entity_present?('badge', swimmer_key)
            badge_entity = find_or_prepare_badge(
              swimmer:, swimmer_key:, team:, team_key: team_name,
              team_affiliation:, category_type:
            )
            add_entity_with_key('badge', swimmer_key, badge_entity)
          end

          badge = cached_instance_of('badge', swimmer_key)
          # DEBUG: ******************************************************************
          # binding.pry if badge.nil? # SHOULD NEVER HAPPEN
          # DEBUG: ******************************************************************

          # TODO/FUTUREDEV: discriminate between ind. results and relay results
          # TODO/FUTUREDEV: add relay results when present (currently: no data available)
          # TODO/FUTUREDEV: add lap timings when present (currently: no data available)

          mir_key = mir_key_for(program_key, swimmer_key)
          next if entity_present?('meeting_individual_result', mir_key)

          score = Parser::Score.from_l2_result(row['score'])
          timing = Parser::Timing.from_l2_result(row['timing'])
          rank = row['pos'].to_i
          mir_entity = find_or_prepare_mir(
            meeting_program:, mprogram_key: program_key,
            swimmer:, swimmer_key:, team:, team_key: team_name,
            team_affiliation:, badge:,
            rank:, timing:, score:
          )
          add_entity_with_key('meeting_individual_result', mir_key, mir_entity)
        end
      end
    end
    # rubocop:enable Metrics/BlockLength
    #-- ------------------------------------------------------------------------
    #++

    # Finds or prepares for creation a Meeting instance (wrapped into an <tt>Import::Entity<tt>)
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

    # Finds or prepares for creation a City instance given its name included in a text address.
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

    # Finds or prepares for creation a SwimmingPool instance given the parameters.
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
      cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::SwimmingPool, { name: pool_name, pool_type_id: pool_type.id })
      if cmd.successful?
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

    # Finds or prepares for creation a MeetingSession instance given all the following parameters.
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

    # Finds or prepares for creation a MeetingEvent instance given all the following parameters.
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
         GogglesDb::MeetingEvent.includes(:meeting).exists?('meetings.id': meeting.id, event_type_id: event_type.id)
        existing_mev = GogglesDb::MeetingEvent.includes(:meeting)
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

    # Finds or prepares for creation a MeetingProgram instance given all the following parameters.
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

    # Finds or prepares for creation a Team instance given its name returning also its possible
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

    # Finds or prepares for creation a team affiliation.
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
    def select_gender_type(sex_code)
      return GogglesDb::GenderType.female if /f/i.match?(sex_code)
      return GogglesDb::GenderType.male if /m/i.match?(sex_code)

      GogglesDb::GenderType.intermixed
    end

    # Finds or prepares for creation a Swimmer instance given its name returning also its possible
    # alternative matches (when found).
    #
    # == Params:
    # - <tt>swimmer_name</tt> => name of the swimmer to find or create
    # - <tt>year</tt> => year of birth of the swimmer
    # - <tt>sex_code</tt> => coded sex string of the swimmer ('M' => male, 'F' => female)
    #
    # == Returns two elements:
    # An Import::Entity wrapping the target row together with a list of all possible candidates, when found.
    def find_or_prepare_swimmer(swimmer_name, year, sex_code)
      gender_type = select_gender_type(sex_code)
      year_of_birth = year.to_i if year.to_i.positive?
      cmd = GogglesDb::CmdFindDbEntity.call(
        GogglesDb::Swimmer,
        { complete_name: swimmer_name, year_of_birth:, gender_type_id: gender_type.id,
          toggle_debug: @toggle_debug == 2 }
      )
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
        if %w[DA DAL DE DEL DI DO LA LE LI LO].include?(tokens.first.upcase)
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
        gender_type_id: gender_type.id,
        year_guessed: year_of_birth.to_i.zero?
      )
      Import::Entity.new(row: new_row, matches: [new_row])
    end

    # Finds or prepares for creation a swimmer badge.
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
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      # ID can be nil for new rows, so we set the association using the new model directly where needed:
      new_row = GogglesDb::Badge.new(
        swimmer_id: swimmer&.id,
        team_affiliation_id: team_affiliation&.id,
        team_id: team&.id,
        season_id: team_affiliation.season_id, # (ASSERT: this will be always set)
        category_type_id: category_type.id,
        entry_time_type_id: entry_time_type.id,
        number: badge_code
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists

    # Finds or prepares for creation a MeetingIndividualResult row given all the following parameters.
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
                            team_affiliation:, badge:, rank:, timing:, score:)
      bindings = {
        'meeting_program' => mprogram_key, 'swimmer' => swimmer_key, 'badge' => swimmer_key,
        'team_affiliation' => team_key, 'team' => team_key
      }
      domain = GogglesDb::MeetingIndividualResult.where(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id, swimmer_id: swimmer&.id
      )
      return Import::Entity.new(row: domain.first, matches: domain.to_a, bindings:) if domain.present?

      new_row = GogglesDb::MeetingIndividualResult.new(
        meeting_program_id: meeting_program&.id,
        team_id: team&.id,
        swimmer_id: swimmer&.id,
        team_affiliation_id: team_affiliation&.id,
        badge_id: badge&.id,
        rank:,
        minutes: timing.minutes,
        seconds: timing.seconds,
        hundredths: timing.hundredths,
        goggle_cup_points: 0.0, # (no data)
        team_points: 0.0, # (no data)
        standard_points: score || 0.0,
        meeting_points: 0.0, # (no data)
        reaction_time: 0.0 # (no data)
      )
      Import::Entity.new(row: new_row, matches: [new_row], bindings:)
    end
    # rubocop:enable Metrics/ParameterLists
    #-- -------------------------------------------------------------------------
    #++

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

    private

    # Returns the internal string key used to access a cached Swimmer entity row.
    #
    # == Params
    # - <tt>swimmer_original_name</tt>: original swimmer name text extracted from the result file "as is"
    #   (not the full name from the matched model row);
    # - <tt>year_of_birth</tt>: GogglesDb::Swimmer#year_of_birth;
    # - <tt>gender_type_code</tt>: GogglesDb::GenderType#code for the swimmer;
    # - <tt>team_original_name</tt>: as above, original team name text extracted from the result file "as is".
    #
    def swimmer_key_for(swimmer_original_name, year_of_birth, gender_type_code, team_original_name)
      "#{swimmer_original_name}-#{year_of_birth}-#{gender_type_code}-#{team_original_name}"
    end

    # Returns the internal string key used to access a cached MeetingEvent entity row.
    #
    # == Params
    # - <tt>event_type_code</tt>: GogglesDb::EventType#code for the event.
    #
    def event_key_for(event_type_code)
      # Use a fixed '1' as session number as long as we can't determine which is which:
      "1-#{event_type_code}"
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
  end
  # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
end
