# frozen_string_literal: true

# = DataFixLegacyController: pre-production editing, all-in-one legacy version
#
# Allows review & edit of imported or crawled data before the push to production.
# (Old admin v1 data-import step 1 & 2)
#
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/PerceivedComplexity
class DataFixLegacyController < ApplicationController
  # Members @solver & @solver.data must be set for all actions (redirects if the JSON parsing fails)
  before_action :set_file_path, :parse_file_contents, :prepare_solver,
                except: [:coded_name, :teams_for_swimmer]

  # [GET] /review_sessions - STEP 1: meeting + session
  #
  # Loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless requested).
  #
  # === About the mapping/"Solving":
  # Whenever a corresponding row is found, the ID is added to the JSON object.
  # Missing rows will be prepared for later creation and the required attributes will be added to the JSON
  # object.
  # At the end of the process, the JSON object will be saved again, overwriting the same file.
  #
  # By reading and parsing the JSON file we can detect if a review phase has been already mapped by
  # looking for certain additional keys inside the data hash.
  # Any entity already mapped to a local Import::Entity will present a key having the destination entity class name
  #
  # For instance:
  # - Meeting => Import::Entity(Meeting) => root key: 'meeting'
  # - MeetingSession => Import::Entity(MeetingSession) => root key: 'meeting_sessions' (plural, because there're usually more than 1)
  # - Team => Import::Entity(Team) => root key: 'teams' (again, plural)
  # (And so on...)
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  def review_sessions
    # Prepare the data review, solving the entities first if not already serialized
    # or when a reparse is requested:
    if @solver.data['meeting'].blank? || @solver.data['meeting_session'].blank? || edit_params['reparse'].present?
      if edit_params['reparse'] == 'sessions'
        @solver.map_sessions
      else # (assume 'reparse whole section')
        @solver.map_meeting_and_sessions
      end

      # Serialize this step overwriting the same file:
      overwrite_file_path_with_json_from(@solver.data)
    end
    prepare_sessions_and_pools
    @retry_needed = @solver.retry_needed
    ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Review sessions: ready' })
  end

  # [POST] /add_session
  # Adds a new MeetingSession structure to the JSON file.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>use_default_pool_key</tt>: when present, it will force a use of the default pool key; that is,
  #   the original name of the pool extracted from the address field of the venue.
  #
  def add_session # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    # Make sure we have Meeting & MeetingSession entities after the JSON parsing (which returns an Hash, not an Entity):
    @solver.rebuild_cached_entities_for('meeting')
    @solver.rebuild_cached_entities_for('meeting_session')
    use_default_pool_key = params['use_default_pool_key'].present?

    new_index = @solver.data['meeting_session'].count
    meeting = @solver.cached_instance_of('meeting', nil)
    last_session = @solver.cached_instance_of('meeting_session', new_index - 1) if new_index.positive?
    # In case last_session is nil (for any reason), use the new index as session order:
    session_order = last_session ? last_session.session_order + 1 : new_index + 1
    pool_name = @solver.data['venue2'].presence || @solver.data['venue1']
    # Use a unique pool name as key, to avoid sharing the same entity among different MeetingSessions:
    pool_name = "#{pool_name}-#{session_order}" unless use_default_pool_key

    new_session = @solver.find_or_prepare_session(
      meeting:,
      session_order:,
      date_day: last_session&.scheduled_date&.day || @solver.data['dateDay1'],
      date_month: last_session ? Parser::SessionDate::MONTH_NAMES[last_session&.scheduled_date&.month&.- 1] : @solver.data['dateMonth1'],
      date_year: last_session&.scheduled_date&.year || @solver.data['dateYear1'],
      scheduled_date: last_session&.scheduled_date,
      pool_name:,
      address: @solver.data['address2'].presence || @solver.data['address1'],
      pool_length: last_session&.swimming_pool&.pool_type&.code || @solver.data['poolLength']
    )
    if new_session
      new_session.add_bindings!('meeting' => @solver.data['name'])
      @solver.data['meeting_session'] << new_session
    end

    # Normalize session entity with cached classes, so that to_json converts them properly:
    @solver.data['meeting_session'].compact! # (No nils in array)
    @solver.rebuild_cached_entities_for('meeting_session')
    overwrite_file_path_with_json_from(@solver.data)

    # Fall back to step 1 (sessions) in case the referrer is not available:
    redirect_to(review_sessions_legacy_path(file_path: file_path_from_params, reparse: nil))
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET] /review_teams - STEP 2: teams
  #
  # As all other review actions, loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless a re-parse has been requested).
  #
  # See #review_sessions for more info.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  def review_teams
    # Prepare the data review, solving the entities first if not already serialized
    # or when a reparse is requested:
    if @solver.data['team'].blank? || edit_params['reparse'].present?
      @solver.map_teams_and_swimmers
      overwrite_file_path_with_json_from(@solver.data)
    end
    @teams_hash = @solver.rebuild_cached_entities_for('team')
    @retry_needed = @solver.retry_needed
    ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Review teams: ready' })
  end

  # [GET] /review_swimmers - STEP 3: swimmers
  #
  # As all other review actions, loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless a re-parse has been requested).
  #
  # See #review_sessions for more info.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  # == Additional params:
  # - page: pagination page number; default 1
  #
  def review_swimmers
    # Prepare the data review, solving the entities first if not already serialized
    # or when a reparse is requested:
    if @solver.data['swimmer'].blank? || edit_params['reparse'].present?
      @solver.map_teams_and_swimmers
      overwrite_file_path_with_json_from(@solver.data)
    end
    @swimmers_hash = @solver.rebuild_cached_entities_for('swimmer')
    @swimmers_keys = @swimmers_hash.keys.sort
    @retry_needed = @solver.retry_needed
    @curr_page = params[:page] || 1
    @max_count = @swimmers_keys.count
    @max_page = @max_count / 300
    @swimmers_keys = Kaminari.paginate_array(@swimmers_keys).page(@curr_page).per(300) if @swimmers_keys.count > 300
    ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Review swimmers: ready' })
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET] /review_events - STEP 4: events
  #
  # Allows editing of the individual MeetingEvents.
  #
  # As all other review actions, loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless a re-parse has been requested).
  #
  # See #review_sessions for more info.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  def review_events
    prepare_for_review_events_and_results
    @retry_needed = @solver.retry_needed
    ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Review events: ready' })
  end

  # [POST] /add_event
  # Adds a new MeetingSession structure to the JSON file.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  #
  def add_event # rubocop:disable Metrics/AbcSize
    # ASSERT: step 1 ("solve meeting & sessions") has already been run
    prepare_sessions_and_pools
    prepare_event_types_payload

    # Make sure we have entities models after the JSON parsing (which returns an Hash, not an Entity):
    @solver.rebuild_cached_entities_for('meeting')
    @solver.rebuild_cached_entities_for('meeting_session')
    @solver.rebuild_cached_entities_for('meeting_event')

    meeting = @solver.cached_instance_of('meeting', nil)
    # Use default first MSession (editable later):
    session_index = add_event_params[:session_index].to_i
    meeting_session = @solver.cached_instance_of('meeting_session', session_index)
    event_type = GogglesDb::EventType.find_by(id: add_event_params[:event_type_id])
    if event_type.blank? || meeting_session.blank?
      flash.now[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to(review_events_legacy_path(file_path: file_path_from_params, reparse: nil))
    end

    # Add a single MeetingEvent only if not present already in the parsed data:
    event_key = @solver.event_key_for(session_index, event_type.code)
    unless @solver.entity_present?('meeting_event', event_key)
      event_order = @solver.data['meeting_event'].count + 1
      mevent_entity = @solver.find_or_prepare_mevent(
        meeting:, meeting_session:, session_index:,
        event_type:, event_order:
      )
      @solver.add_entity_with_key('meeting_event', event_key, mevent_entity)
    end

    overwrite_file_path_with_json_from(@solver.data)
    # Fall back to step 1 (sessions) in case the referrer is not available:
    redirect_to(review_events_legacy_path(file_path: file_path_from_params, reparse: nil))
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET] /review_results - STEP 5: results
  #
  # No editing supported: the same data parsed from step 4 is presented as a "final report", before
  # committing the edited changes inside the JSON file to the batch SQL builder.
  #
  # As all other review actions, loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless a re-parse has been requested).
  #
  # See #review_sessions for more info.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  def review_results
    prepare_for_review_events_and_results
    # Extract all Prgs & MIRs keys, giving up the rest (including bindings & matches) since we won't use them here:
    @prgs_keys = @solver.data['meeting_program']&.keys
    @mirs_keys = @solver.data['meeting_individual_result']&.keys
    @laps_keys = @solver.data['lap']&.keys
    @mrrs_keys = @solver.data['meeting_relay_result']&.keys
    @mrss_keys = @solver.data['meeting_relay_swimmer']&.keys
    @ts_keys = @solver.data['meeting_team_score']&.keys
    @retry_needed = @solver.retry_needed
    ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Review results: ready' })
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
  end
  #-- -------------------------------------------------------------------------
  #++

  # [PATCH /data_fix/update]
  # Updates the model fields storing the values directly into the JSON file and then redirects to the
  # page that issued the original request when possible.
  #
  # The specified model name dictates the main entity to be edited/created. Each main entity may have
  # a variable list of bindings (sub-entities) that need to be taken into account.
  #
  # Usually, only the first-level entity bindings needs to be handled.
  #
  # However, currently this supports also the creation (or the update) for deeper bindings for:
  #
  # - SwimmingPool (as child of MeetingSession, inside a Meeting)
  # - City (as child of SwimmingPool, inside a MeetingSession)
  #
  # Creation of new Cities from Team bindings is currently unsupported.
  #
  # == Params:
  # <tt>:model</tt> => the model name in snake case, singular
  #
  # <tt><MODEL_NAME></tt> => same value of the <tt>:model</tt> parameter but acting as key of an array of Hash of
  #                          column attributes with values. (E.g.: <tt>'team' => { index => { ...Team attributes with values... } }</tt>)
  #
  #
  # == MeetingSession: update request PARAMS format example
  #   {
  #     "_method"=>"patch", "authenticity_token"=>"<token>", "file_path"=>"/full/file_path.json",
  #     "key"=>"0", // Current meeting session index
  #     "meeting_session" => {
  #       "description"=>"Sessione 1, 2021-11-06", "session_order"=>"1", "scheduled_date"=>"2021-11-06", "day_part_type_id"=>"1"
  #     },
  #     "swimming_pool" => { // (Supports 1 pool per meeting session)
  #       "0" => {
  #         "swimming_pool_id"=>"68", "swimming_pool"=>"", "nick_name"=>"civitavecchiastadionuotomarcogalli50",
  #         "pool_type_id"=>"2"
  #       }
  #     },
  #     "city" => {          // (Supports 1 city per meeting session, always linked as swimming_pool.city_id)
  #       "0" => {
  #         "city_id"=>"65", "city"=>"", "area"=>"Roma", "country_code"=>"IT",
  #         "key"=>"Roma"
  #       }
  #     },
  #     "model"=>"meeting_session", "controller"=>"data_fix", "action"=>"update"
  #   }
  #
  # In the above example, the 'key' attribute in the 'city' binding is the actual key used to retrieve
  # the cached version of the City entity from the JSON data hash.
  #
  #
  # == Team: update request PARAMS format example
  #
  # {
  #   "authenticity_token" => "<token", "key"=>"Circolo Canottieri Aniene", "file_path"=>"/full/file_path.json",
  #   "team" => {
  #     "Circolo Canottieri Aniene" => {
  #       "team_id"=>"89", "team"=>"", "editable_name"=>"C.C. ANIENE ASD",
  #       "city_id"=>"", "city"=>"", "area"=>"", "country_code"=>""
  #     }
  #   },
  #   "model"=>"team"
  # }
  #
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def update
    model_name = edit_params['model'].to_s
    # Used in case of swimmer attribute editing:
    actual_attrs = {}
    prev_year_of_birth = nil
    prev_gender_type_id = nil

    # == NOTE:
    # The entity Key used to retrieve the entity from the data hash should *never* change.
    #
    # Nevertheless, when the string key has special chars in it (like most team names),
    # Rails form helpers may convert its field namespace using underscores when rendering
    # DOM IDs.
    #
    # Notably, as of this writing, this doesn't work well for dots (e.g. as in key="S. Donato"),
    # which will become a form field namespace in brackets ("team[S. Donato][id]")
    # and a snail-cased name for IDs ("team_S._Donato_id"), which doesn't work at all
    # with document.querySelector().
    #
    # So we pass both the converted form DOM IDs (to make event changes on the form always
    # work) and the actual key for the entity inside the data hash.
    #
    # == Bottom line:
    # - Whenever there's a 'edit_params', to retrieve the values we need the 'actual_form_key?
    # - Whenever we access the @solver.data we need the real 'entity_key'.

    entity_key = entity_key_for(model_name)
    actual_form_key = if edit_params['dom_valid_key'].present? && edit_params['dom_valid_key'] != entity_key
                        edit_params['dom_valid_key']
                      else
                        entity_key
                      end

    # == Main entity update: ==
    updated_attrs = if model_name == 'meeting'
                      # (Meetings don't use the entity key because they are 1 for each file)
                      edit_params[model_name]
                    else
                      # (Request params multi-row index always a string)
                      edit_params[model_name]&.fetch(actual_form_key.to_s, nil)
                    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
    if updated_attrs.present?
      # Reject any patch param attribute not belonging to the destination list of actual model attributes:
      actual_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, model_name)
      # Always overwrite the fuzzy result ID column with the manual lookup result ID, which has a higher priority:
      # (i.e.: 'team_id' => team['id'])
      actual_attrs['id'] = if updated_attrs["#{model_name}_id"].present?
                             updated_attrs["#{model_name}_id"]
                           elsif actual_attrs['id'].to_i.zero? # Avoid clearing if present
                             actual_attrs['id'] = nil # Allow clearing of ID using zero
                           end
      # Handle special cases: name changes, YOB changes, ID clearing
      case model_name
      when 'team'
        # Avoid empty Team names:
        actual_attrs['name'] = updated_attrs['team'].presence || updated_attrs['editable_name'] if actual_attrs['name'].blank?
        # Prepend variations unless already there:
        unless actual_attrs['name_variations'].include?(actual_attrs['name'])
          actual_attrs['name_variations'] =
            "#{actual_attrs['name']};#{actual_attrs['name_variations']}"
        end
        unless actual_attrs['name_variations'].include?(actual_attrs['editable_name'])
          actual_attrs['name_variations'] =
            "#{actual_attrs['editable_name']};#{actual_attrs['name_variations']}"
        end

        # Need to clear the TeamAffiliation association? (Happens when setting matched team => blank)
        if actual_attrs['id'].blank? && @solver.data['team_affiliation']&.fetch(entity_key, nil).present?
          ta_entity = @solver.data['team_affiliation']&.fetch(entity_key, nil)
          # New team => new TeamAffiliation with nil team_id (to be set by MacroCommitter using bindings)
          ta_entity['row']['id'] = nil
          ta_entity['row']['team_id'] = nil
        end

      when 'swimmer'
        # Overwrite complete name when the lookup values change:
        actual_attrs['complete_name'] = updated_attrs['swimmer'].presence || "#{updated_attrs['last_name']} #{updated_attrs['first_name']}"
        swimmer = @solver.data['swimmer']&.fetch(entity_key, nil)&.fetch('row', {})
        prev_year_of_birth = swimmer&.fetch('year_of_birth', nil)
        prev_gender_type_id = swimmer&.fetch('gender_type_id', nil)

        # Need to clear the Badge association? (Happens when setting matched swimmer => blank)
        if actual_attrs['id'].blank? && @solver.data['badge']&.fetch(entity_key, nil).present?
          badge_entity = @solver.data['badge']&.fetch(entity_key, nil)
          # New swimmer => new badge with nil swimmer_id (to be set by MacroCommitter using bindings)
          badge_entity['row']['id'] = nil
          badge_entity['row']['swimmer_id'] = nil
        end
      end
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------

      # === Update main entity attributes: ===
      # (index must be already set to the proper key type: nil for meetings, integer for sessions, string for others)
      if entity_key.present?
        @solver.data[model_name]&.dig(entity_key, 'row')&.compact!
        @solver.data[model_name]&.dig(entity_key, 'row')&.merge!(actual_attrs)
      else
        @solver.data[model_name]&.fetch('row', nil)&.compact!
        @solver.data[model_name]&.fetch('row', nil)&.merge!(actual_attrs)
      end
    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # == Bindings update: ==
    deep_nested_bindings = @solver.cached_instance_of(model_name, entity_key, 'bindings')
    city_updatable_fields = %w[name zip area country country_code latitude longitude]
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    deep_nested_bindings.each do |binding_model_name, binding_key| # rubocop:disable Metrics/BlockLength
      # *** Sub-binding update EXCEPTIONS that update the corresponding entity directly:
      # Check for specific binding & model names:
      # - "team" -> "team_affiliation"
      if binding_model_name == 'team_affiliation' && model_name == 'team'
        # Direct update of the TA entity using involved Team attributes (TeamAffiliations & Teams have the same key):
        @solver.data['team_affiliation']&.dig(entity_key, 'row')&.merge!(
          'team_id' => edit_params['team']&.dig(actual_form_key.to_s, 'team_id'),
          'name' => edit_params['team']&.dig(actual_form_key.to_s, 'editable_name')
        )
      # Indipendently from binding_model_name, valid for 'city' only:
      # - "meeting_session" -> "swimming_pool" (-> "city")
      # - "team" -> "city"
      elsif edit_params['city'].present? && edit_params['city'][actual_form_key.to_s].present? &&
            edit_params['city'][actual_form_key.to_s]['key'].present?
        # NOTE: City is the only "complex" binding that could be sub-nested at depth > 1
        # 1. model_name: [MeetingSession] -> explicit binding1: [SwimmingPool] -> implicit sub-binding: [City] (fields in edit_params)
        # 2. model_name: [Team] -> explicit binding1: [City] (fields in edit_params)
        # => Update the cached city entity (without changing its sub-binding key) directly using the ID when
        #    provided in the edit_params because the form won't include all fields for nestings at depth > 1 and
        #    the cached entity may need those during the MacroCommitter phase:
        cached_key = edit_params['city'][actual_form_key.to_s]['key']
        # DEBUG ----------------------------------------------------------------
        # binding.pry
        # ----------------------------------------------------------------------

        # Retrieve and overwrite the cached entity whenever a new City ID is given:
        if edit_params['city'][actual_form_key.to_s]['city_id'].present?
          city_id = edit_params['city'][actual_form_key.to_s]['city_id']
          area = edit_params['city'][actual_form_key.to_s]['area']
          @solver.data['city'][cached_key] = @solver.find_or_prepare_city(city_id, cached_key, area).to_hash
        end
        # Update fields in the cached city entity using the form inputs:
        city_updatable_fields.each do |field|
          @solver.data['city'][cached_key]['row'][field] = edit_params['city'][actual_form_key.to_s][field]
        end
      end

      updated_attrs = edit_params[binding_model_name]&.fetch(actual_form_key.to_s, nil)
      next if updated_attrs.blank?

      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------
      # Handle the special case in which we want to update the key/index of a binding in the main entity:
      # (not the association column ID value itself -- currently this is implemented & supported only for
      #  the meeting events form, given that both events & sessions will typically be new & ID-less each time)
      if binding_model_name != 'city' && updated_attrs.key?('key') # (special/bespoke sub-association form field naming for binding keys)
        # Try to detect invalid form indexes:
        if updated_attrs['key'].to_s.size != 1
          raise("ERROR: bindings key for ['#{model_name}']['#{entity_key}'] is potentially invalid: '#{updated_attrs['key']}', it should be a single-digit integer or string.")
        end

        @solver.data[model_name]&.dig(entity_key, 'bindings')&.merge!(
          # ASSERT: key here is a form index, not a string key
          { binding_model_name => updated_attrs['key'].to_i }
        )
      end

      # Use as association key for the binding in main entity its correct column name in main entity:
      # (For ex.: 'swimming_pool' => { 'swimming_pool_id' => 1 } instead of "'swimming_pool'['id']")
      main_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, model_name)
      nested_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, binding_model_name)

      # == Update association column in main entity (if there are attributes to be updated):
      if entity_key.present? && main_attrs.present?
        # i.e.: 'swimming_pool' => 0 => 'swimming_pool_id' (apply to main, i.e.: 'meeting_session')
        @solver.data[model_name]&.dig(entity_key, 'row')&.compact!
        @solver.data[model_name]&.dig(entity_key, 'row')&.merge!(main_attrs)
      elsif main_attrs.present? && model_name != 'meeting_session'
        # Only 'meeting' doesn't have a key (the bindings, if any, must use it):
        @solver.data[model_name]&.fetch('row', nil)&.compact!
        @solver.data[model_name]&.fetch('row', nil)&.merge!(main_attrs)
      end
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------
      # No more attributes or sub-attributes updates needed for city after this point:
      # (City cached entity as been already updated above)
      # next if binding_model_name == 'city'

      # === Update binding entity attributes too: ===
      raise "ERROR: using a 'binding_key' Hash for updates isn't supported anymore: #{binding_key.inspect} (it was used for City before)" if binding_key.is_a?(Hash)

      # i.e.: 'swimming_pool' => 0 => 'city_id' (apply to binding, i.e.: 'swimming_pool')
      # Always add the overwrite for the binding fuzzy result ID column with the manual-lookup result ID:
      nested_attrs['id'] = if updated_attrs["#{binding_model_name}_id"].present?
                             updated_attrs["#{binding_model_name}_id"].to_i
                           elsif nested_attrs['id'].to_i.zero? # Avoid clearing if empty or present
                             nested_attrs['id'] = nil # Allow clearing of ID using zero
                           end
      # Overwrite the bindings to city ID inside the current binding model row:
      # (ASSUMES: if the form presents a city as editable, then it must be part of its sub-nested bindings)
      if edit_params['city'].present? && edit_params['city'][actual_form_key.to_s].present? &&
         edit_params['city'][actual_form_key.to_s]['key'].present?
        nested_attrs['city_id'] = edit_params['city'][actual_form_key.to_s]['city_id']
      end
      @solver.data[binding_model_name]&.dig(binding_key, 'row')&.compact!
      @solver.data[binding_model_name]&.dig(binding_key, 'row')&.merge!(nested_attrs)
    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # NOTE: at this point 'actual_attrs' have been already applied to the main entity and its direct bindings
    check_for_category_change_and_adjust_results(entity_key, prev_year_of_birth, prev_gender_type_id, actual_attrs) if model_name == 'swimmer'
    # (^ this will return immediately if there are no changes to the category or gender to be made)

    # == Serialization on same file: ==
    overwrite_file_path_with_json_from(@solver.data)

    # Clean the referer URL from a possible reparse parameter before redirecting back:
    request.headers['HTTP_REFERER'].gsub!(/&reparse=(true|sessions)/i, '')
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # Fall back to step 1 (sessions) in case the referrer is not available:
    redirect_back(fallback_location: review_sessions_legacy_path(file_path: file_path_from_params, reparse: false))
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  #-- -------------------------------------------------------------------------
  #++

  # [DELETE /data_fix/purge]
  # Deletes the specified model from the JSON file.
  # Usable to remove possible NEW duplicates of Teams or Swimmers added to the resulting Hash structure
  # due to slight naming differences.
  #
  # == Typical example:
  # 1. a Team name gets parsed slightly differently in 2 different contexts;
  # 2. the same Swimmer (name & birth year) gets associated to these 2 different team names (for its key);
  # 3. if the Swimmer is "new" (no preexisting row has been found) a duplicate row will be created
  #    when solving & committing the entities (due to the slightly different ending keys).
  #
  # == Note:
  # This is callable only before starting the "review results" phase as, after that,
  # teams & swimmers will be already bound to results and removing them will corrupt
  # the resulting JSON structure.
  #
  # Although this action is generic due to using the model parameter, this currently supports
  # only a limited number of cached models (see below).
  #
  # == Params:
  # <tt>:file_path</tt> => source JSON file for the data Hash containing all entities;
  # <tt>:model</tt> => the model name in snake case, singular;
  #                    supports only: swimmer, team, meeting_session, meeting_event;
  # <tt>:key</tt> => string key for the model entity in the parsed data hash from the JSON file.
  #
  def purge # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
    model_name = edit_params['model'].to_s
    unless %w[swimmer team meeting_session meeting_event].include?(model_name)
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path)
    end

    # 1) Get the proper key from params and delete the chosen cached entity
    #    to avoid duplication errors during creation:
    entity_key = entity_key_for(model_name)

    # 2) Delete the cached entity:
    # Array (index) or Hash (key) deletion?
    if @solver.data[model_name].respond_to?(:delete_at)
      @solver.data[model_name].delete_at(entity_key)
    else
      @solver.data[model_name]&.delete(entity_key)
    end

    # 3) Delete also just the primary existing cached badge or affiliation with the same key:
    if model_name == 'swimmer'
      @solver.data['badge']&.delete(entity_key)
    elsif model_name == 'team'
      @solver.data['team_affiliation']&.delete(entity_key)
    end

    # 4) HANDLE DUPLICATES (just for 'team' or 'swimmer') / GET THE UPDATED JSON:
    corrected_json = handle_duplicates_in_json_data_for(model_name, entity_key)

    # 5) Update JSON data file contents:
    FileUtils.rm_f(@file_path)
    File.write(@file_path, corrected_json)

    # Clean the referer URL from a possible reparse parameter before redirecting back:
    request.headers['HTTP_REFERER'].gsub!(/&reparse=(true|sessions)/i, '')

    # Fall back to step 1 (sessions) in case the referrer is not available:
    redirect_back(fallback_location: review_sessions_legacy_path(file_path: file_path_from_params, reparse: false))
  end
  #-- -------------------------------------------------------------------------
  #++

  # [GET /coded_name] (JSON only)
  # Computes and returns just the coded name as JSON, given the parameters.
  #
  # == Params:
  # <tt>:target</tt> => target for the coded name value; supports 'code' (Meeting) or
  #                     'nick_name' (SwimmingPool)
  #
  # === Required options for Meeting's 'code' target:
  # - 'description' & 'city_name'
  #
  # === Required options for SwimmingPool's 'nick_name' target:
  # - 'name', 'city_name' & 'pool_type_code'
  #
  # == Returns:
  # A JSON response having format:
  #
  #    { coded_name: <internal_coded_name> }
  #
  # rubocop:disable Metrics/AbcSize
  def coded_name
    unless request.format.json? && %w[code nick_name].include?(coded_name_params[:target])
      flash[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to root_path
      return
    end

    result = if coded_name_params[:target] == 'nick_name'
               GogglesDb::Normalizers::CodedName.for_pool(
                 coded_name_params[:name],
                 coded_name_params[:city_name],
                 coded_name_params[:pool_type_code]
               )
             else
               GogglesDb::Normalizers::CodedName.for_meeting(
                 coded_name_params[:description],
                 coded_name_params[:city_name]
               )
             end

    render(json: { coded_name_params[:target] => result })
  end
  # rubocop:enable Metrics/AbcSize

  # [GET /teams_for_swimmer] (AJAX only)
  # Computes and returns the rendered text displaying the list of unique team names
  # for which the specified swimmer_id results having a badge for.
  # Returns an empty text otherwise.
  #
  # == Params:
  # <tt>:swimmer_id</tt> => target Swimmer id (required)
  #
  def teams_for_swimmer
    unless request.xhr?
      flash[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to root_path
      return
    end

    @swimmer_id = teams_for_swimmer_params[:swimmer_id]
    @team_names = GogglesDb::Badge.where(swimmer_id: @swimmer_id)
                                  .includes(:team).joins(:team)
                                  .map { |row| "#{row.team.editable_name} (#{row.team_id})" }
                                  .uniq
                                  .join(', ')
  end

  # [GET /result_details] (AJAX only)
  # Returns the rendered HTML text for showing the result details for the specified row in
  # the selected class.
  # Returns an empty text otherwise.
  #
  # == Params:
  # <tt>:row_class</tt> => snail_case name of the result class type ('meeting_individual_result' or 'meeting_relay_result')
  # <tt>:row_key</tt> => string key for the row stored inside @solver.data
  #
  def result_details # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    unless request.xhr?
      flash[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to root_path
      return
    end

    relay = result_details_params[:relay] == 'true'
    prg_key = result_details_params[:prg_key]
    @target_dom_id = result_details_params[:target_dom_id]
    row_type = relay ? 'meeting_relay_result' : 'meeting_individual_result'
    lap_type   = relay ? 'meeting_relay_swimmer' : 'lap'

    prg_checker = Regexp.new(prg_key, Regexp::IGNORECASE)
    # Retrieve several result rows & laps for each MeetingProgram:
    # (Check actual bindings to support "movable" MPrgs for MIRs/MRSs/Laps)
    @res_rows = @solver.data[row_type].select { |_k, hsh| hsh['bindings']['meeting_program'] == prg_key }
    @res_laps = @solver.data[lap_type].select { |_k, hsh| hsh['bindings']['meeting_program'] == prg_key }
    @sub_laps = @solver.data['relay_lap']&.select { |row_key, _v| prg_checker.match?(row_key) } if relay
    @res_laps.merge!(@sub_laps) if @sub_laps.present?
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
  end

  private

  # Strong parameters checking for file & edit (patch) related actions.
  def edit_params
    # Allow any sub-hash indexed with the current model name specified as a parameter:
    # (typically: 'team' => { index => { <team attributes> } })
    params.permit(
      :action, :reparse, :model, :key, :dom_valid_key, :file_path, :shared_place, :raw_lt4,
      swimming_pool: {}, city: {}, meeting: {}, meeting_session: {}, meeting_event: {}, meeting_program: {},
      team: {}, swimmer: {}, badge: {},
      meeting_individual_result: {}, lap: {}, meeting_relay_result: {}, meeting_relay_swimmer: {}
    )
  end

  # Strong parameters checking for coded name retrieval.
  def coded_name_params
    params.permit(
      :action, :target,
      :name, :city_name, :pool_type_code,
      :description
    )
  end

  # Strong parameters checking for team names list retrieval.
  def teams_for_swimmer_params
    params.permit(:swimmer_id)
  end

  # Strong parameters checking for team names list retrieval.
  def result_details_params
    params.permit(:relay, :prg_key, :target_dom_id)
  end

  # Strong parameters checking for POST 'add_event'.
  def add_event_params
    params.permit(:event_type_id, :event_type_label, :session_index)
  end

  # Returns the correct type of <tt>edit_params['key']</tt> depending on the specified <tt>model_name</tt>.
  def entity_key_for(model_name)
    case model_name
    when 'meeting'
      nil
    when 'meeting_session'
      edit_params['key'].to_i
    else
      edit_params['key'].to_s
    end
  end

  # Returns the currently processed file path from any of the 2 possible parameter combinations
  # (either, at root with 'file_path' as key, or nested inside the row details, using '_file_path' as key).
  def file_path_from_params
    # (Example: { 'file_path' => <file path string> })
    return edit_params[:file_path] if edit_params[:file_path].present?

    # Assumes the file path shouldn't change in between model rows, so the following should be ok
    # even when params stores more than 1 row of model attributes:
    # (Example: { 'team' => { <any_team_index> => { 'file_path' => <file path string>, <other team attributes...> } } })
    edit_params[params[:model]]&.values&.first&.[]('file_path')
  end

  # Setter for @file_path; expects the 'file_path' parameter to be present.
  # Sets also @api_url.
  def set_file_path
    @api_url = "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    @file_path = file_path_from_params
    return if @file_path.present?

    flash[:warning] = I18n.t('data_import.errors.invalid_request')
    redirect_to(pull_index_path)
  end

  # Parses the contents of @file_path assuming it's valid JSON.
  # Sets @data_hash with the parsed contents, which shall be used to initialize the @solver member.
  # Redirects to #pull/index in case of errors.
  def parse_file_contents
    file_content = File.read(@file_path)
    begin
      @data_hash = JSON.parse(file_content.force_encoding('UTF-8'))
      # Optional pre-normalization filtering and cleanup for LT4 heavy files
      if @data_hash.is_a?(Hash) && @data_hash['layoutType'].to_i == 4
        # 1) Filter events by codes if requested (pre-adapter)
        if params[:only_event_codes].present? && @data_hash['events'].is_a?(Array)
          codes = params[:only_event_codes].to_s.split(',').map(&:strip).compact_blank
          @data_hash['events'].select! { |evt| codes.include?(evt['eventCode']) }
        end
        # 2) Drop root dictionaries early unless requested to keep
        unless params[:keep_dictionaries] == 'true'
          @data_hash.delete('swimmers')
          @data_hash.delete('teams')
        end
      end

      # Normalize LT4 (Microplus) files into canonical LT2-like schema unless explicitly bypassed
      if @data_hash.is_a?(Hash) && @data_hash['layoutType'].to_i == 4 && params[:raw_lt4] != 'true'
        @data_hash = Import::Adapters::Layout4To2.normalize(data_hash: @data_hash)
        # 3) Optionally strip laps arrays from rows after normalization to reduce memory/size
        case params[:strip_laps]
        when 'individual'
          @data_hash['sections'].to_a.each do |sec|
            sec['rows'].to_a.each do |row|
              row.delete('laps') unless row['relay']
            end
          end
        when 'all'
          @data_hash['sections'].to_a.each do |sec|
            sec['rows'].to_a.each { |row| row.delete('laps') }
          end
        end
      end
    rescue StandardError
      flash[:error] = I18n.t('data_import.errors.invalid_file_content')
      redirect_to(pull_index_path) && return
    end
  end

  # Returns a valid Season assuming current +@file_path+ contains the season ID as
  # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
  # Defaults to season ID 212 if no valid integer was found in the last folder of the path.
  # Sets @season with the specific Season retrieved.
  def detect_season_from_pathname
    season_id = File.dirname(@file_path).split('/').last.to_i
    season_id = 212 unless season_id.positive?
    @season = GogglesDb::Season.find(season_id)
  end

  # Prepares the @solver instance assuming @data_hash & @file_path have been already set.
  # Sets @solver with current Solver instance.
  def prepare_solver
    detect_season_from_pathname # (sets @season)
    @solver = Import::MacroSolver.new(season_id: @season.id, data_hash: @data_hash, toggle_debug: false)
  end

  # Assuming @solver.data contains already "solved" data for meeting & sessions, this sets
  # the @meeting_sessions & @swimming_pools member arrays with the current data found in the
  # Hash, building the proper corresponding models for each one.
  def prepare_sessions_and_pools # rubocop:disable Metrics/AbcSize
    @solver.rebuild_cached_entities_for('city')
    @meeting_entity = @solver.rebuild_cached_entities_for('meeting')
    @meeting = @meeting_entity.row

    @meeting_sessions = []
    @swimming_pools = []
    @cities = []
    @city_keys = []

    # Don't consider nil results as part of the list:
    @solver.data['meeting_session']&.compact!
    @solver.data['meeting_session']&.each_with_index do |_item, index|
      @meeting_sessions[index] = @solver.cached_instance_of('meeting_session', index)
      pool_key = @solver.cached_instance_of('meeting_session', index, 'bindings')&.fetch('swimming_pool', nil)
      # Get the Pool as first-class citizen of the form (for update/create):
      next if pool_key.blank?

      @swimming_pools[index] = @solver.cached_instance_of('swimming_pool', pool_key)
      # Get also the City as first-class citizen of the form:
      city_key = @solver.cached_instance_of('swimming_pool', pool_key, 'bindings')&.fetch('city', nil)
      if city_key.present?
        @cities[index] = @solver.cached_instance_of('city', city_key)
        @city_keys[index] = city_key
      end
    end
  end

  # Setter for <tt>@event_types_payload</tt>.
  # Collects all eventable EventTypes into a payload array that can be used to feed an autocomplete
  # component for selecting a specific EventType ID.
  def prepare_event_types_payload
    @event_types_payload = GogglesDb::EventType.all_eventable.map do |event_type|
      {
        'id' => event_type.id,
        'search_column' => event_type.label,
        'label_column' => event_type.label,
        'long_label' => event_type.long_label
      }
    end
  end

  # Serializes the specified <tt>data_hash</tt> as JSON text, erasing first the file at <tt>@file_path</tt> if found existing,
  # and then rewriting all contents of the specified Hash (as JSON) over the same <tt>@file_path</tt>.
  # Assumes <tt>data_hash</tt> responds to <tt>:to_json</tt>.
  def overwrite_file_path_with_json_from(data_hash)
    contents = data_hash.to_json.force_encoding('UTF-8')
    FileUtils.rm_f(@file_path)
    File.write(@file_path, contents)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Common implementation for both STEP 4 & STEP 5: events & results.
  # Same action method, different view of the data.
  #
  # Results won't be editable, instead a summary will be presented for each event & program.
  #
  # As all other review actions, loads the specified JSON data file and prepares the data for review/edit.
  # If the entities for this phase have been "solved" & mapped already into the JSON data file,
  # no additional parsing ("solving") will be done (unless a re-parse has been requested).
  #
  # See #review_sessions, #review_events & #review_results for more info.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  # - <tt>reparse</tt>: when present, it will force a reparsing of this section using the MacroSolver.
  #
  def prepare_for_review_events_and_results
    # ASSERT: step 1 ("solve meeting & sessions") has already been run
    prepare_sessions_and_pools
    if @solver.data['team'].blank? || @solver.data['swimmer'].blank?
      @solver.map_teams_and_swimmers
      ActionCable.server.broadcast('ImportStatusChannel', { msg: 'Map teams & swimmers: done.' })
    end
    prepare_event_types_payload

    # Prepare the data to be reviewed, solving the entities first when not already serialized:
    # (or when a reparse is not requested)
    if @solver.data['meeting_event'].blank? || edit_params['reparse'].present?
      @solver.map_events_and_results
      # Prevent empty rows in source data arrays to clutter the structure (it happens frequently):
      @solver.data['meeting_event']&.compact!
      overwrite_file_path_with_json_from(@solver.data)
    end
    @events_hash = @solver.rebuild_cached_entities_for('meeting_event')
    @prgs_hash = @solver.rebuild_cached_entities_for('meeting_program')
  end
  #-- -------------------------------------------------------------------------
  #++

  # Handles possible duplicates in 'swimmer' or 'team' models in the JSON data
  # by removing any reference to the specified <tt>entity_key</tt>.
  # Requires the internal @solver (MacroSolver) instance to be already defined and ready.
  #
  # == Params:
  # - <tt>model_name</tt>: the model name in snake case, singular;
  #                        supports only: swimmer, team;
  #
  # - <tt>deleted_entity_key</tt>: the (already) deleted key of the entity to be purged from
  #                        all bindings references inside the JSON data.
  #
  # == Returns:
  # Returns the updated JSON data file after deleting any possible reference to the
  # specified entity key.
  #
  def handle_duplicates_in_json_data_for(model_name, deleted_entity_key)
    return @solver.data.to_json unless %w[swimmer team].include?(model_name)

    # 4.1) Retrieve the list of keys for this model to detect remaining candidate(s):
    cache_keys = @solver.rebuild_cached_entities_for(model_name).keys

    # 4.2) Get the first key matching the one just deleted and use it as a candidate
    #      for a global string subst among the resulting JSON (so that we can easily
    #      update the bindings too):
    existing_key_part = model_name == 'swimmer' ? deleted_entity_key.split(/-\d{4}-/).first : deleted_entity_key
    new_key = cache_keys.find { |ckey| ckey.starts_with?(existing_key_part) }

    # Handle special chars ('&', '<', '>') that get automatically escaped in Unicode in the resulting JSON
    # for the substitution matcher:
    deleted_entity_key = deleted_entity_key.gsub('&', '\\\\\\u0026').gsub('<', '\\\\\\u003c').gsub('>', '\\\\\\u003e')
    # The Unicode escape sequence code must be escaped 3 times for the double backlash to be present
    # in the final Regexp, so that the substitution of the keys actually takes place.
    # Example:
    # > Regexp.new('SWIM&FITNESS'.gsub('&', '\\\\u0026'), Regexp::IGNORECASE)
    # => /SWIM\u0026FITNESS"/i   # (this won't match the saved data.to_json, enforced encoding or not)
    # > Regexp.new('SWIM&FITNESS'.gsub('&', '\\\\\\u0026'), Regexp::IGNORECASE)
    # => /SWIM\\u0026FITNESS"/i  # (this will)

    # NOTE: matching the ending quote of the deleted key allows us to substitute
    #       shorter keys with longer ones in the bindings without changing the existing longer strings
    subst_matcher = Regexp.new("#{deleted_entity_key}\"", Regexp::IGNORECASE)

    # 4.3) Substitute the deleted key with the new one, allegedly matching most
    #      of the data, and save the JSON file overwriting the existing one:
    @solver.data.to_json.gsub(subst_matcher, "#{new_key}\"")
    # NOTE: when there are 3 or more possible duplicates, this will overwrite
    #       all references of the deleted key with just the first remaining candidate
    #       (which may not be the one intended to remain in the data)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Propagates the changes to a Swimmer entity row after a gender type or YOB override, which may imply
  # a category change and, consecutively, a MeetingProgram update for all linked sub-entities (results and laps).
  #
  # This method assumes the updated attributes have already been applied to the Swimmer row and its direct
  # bindings (namely, just its Badge). Which leaves out all results and laps tied to a specific MPrg
  # (which may change whenever the category or the gender changes).
  #
  # A gender type override always implies a meeting program change. A YOB override may or may not, depending
  # on the associated category type range (which spans 5 years).
  # Whenever the category change happens, this resolves to:
  # - changing the swimmer's badge (linked to a category) -- this is assumed to be already taken care of;
  # - changing any mapped MIRs, Laps or MRSs associated to the same MeetingProgram with the new correct values;
  #   that is, moving any existing MIRs, Laps or MRSs to the correct MPrg given the correct category/gender.
  #
  # In any case, the involved entities keys should *never* change (so that any subsequent purge may
  # pinpoint uniquely to each possibly duplicated row for correct deletion).
  #
  # The method will return immediately if there are no relevant changes to the swimmer entity (YOB and/or gender) and,
  # in case, will edit @solver.data directly without saving it to file.
  #
  # == Params:
  # - <tt>swimmer_key</tt>: cached entity key to be processed;
  # - <tt>prev_year_of_birth</tt>: value of the swimmer's YOB before applying the updated attributes;
  # - <tt>prev_gender_type_id</tt>: value of the swimmer's gender_type_id before applying the updated attributes;
  # - <tt>updated_attrs</tt>: updated attributes for the swimmer entity.
  #
  def check_for_category_change_and_adjust_results(swimmer_key, prev_year_of_birth, prev_gender_type_id, updated_attrs) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    return if swimmer_key.blank? || prev_year_of_birth.blank? || prev_gender_type_id.blank? || updated_attrs.blank? ||
              (prev_gender_type_id == updated_attrs['gender_type_id'].to_i && prev_year_of_birth == updated_attrs['year_of_birth'].to_i)

    # Rebuild the cache for the involved sub entities (as hash of {key: ImportEntity}) so that they're easier to handle:
    badges_hash = @solver.rebuild_cached_entities_for('badge')
    badge_row = badges_hash&.fetch(swimmer_key, nil)&.row
    # DEBUG ----------------------------------------------------------------
    # binding.pry if badge_row.blank?
    # ^^ This may happen only if the swimmers weren't *all* properly mapped when reaching this point
    # (i.e.: after a "teams & swimmers"-only partial scan, without scanning also all results)
    # ----------------------------------------------------------------------
    raise "Badge not found for swimmer key: #{swimmer_key}" if badge_row.blank?

    # Always compute the target category code & type:
    cat_code, category_type = @solver.post_compute_ind_category(updated_attrs['year_of_birth'].to_i)
    # Fallback to current category code & type in badge if the computed one is not valid:
    cat_code, category_type = @solver.categories_cache.find_category_by_id(badge_row.category_type_id, relay: false) if cat_code.blank? || category_type.blank?

    # WARNING: proper relay category change/adjust is NOT currently supported! (Even in case of swimmer YOB editing!)
    # For relays, in order to use "categories_cache.find_category_for_age(overall_age, relay: true)",
    # all the swimmers belonging to the MRR result should be collected to compute the overall age.
    # (MRS aren't always present, age is not always known, etc.)

    # Regardless of YOB change, category change can be detected by simply comparing it to the badge's one:
    category_change = category_type.present? && category_type.id != badge_row.category_type_id

    # - Possible gender change? => follow same steps above
    gender_change = (prev_gender_type_id != updated_attrs['gender_type_id'].to_i) && updated_attrs['gender_type_id'].to_i.positive?
    return unless category_change || gender_change # Bail out unless there's a MPrg change

    gender_code = updated_attrs['gender_type_id'].to_i == GogglesDb::GenderType::FEMALE_ID ? GogglesDb::GenderType.female.code : GogglesDb::GenderType.male.code

    # == NOTE: APPROXIMATED SOLUTION WARNING!
    # The following assumes all mapped data inside the cache is "complete" (Laps have bindings on MIRs and so on);
    # this doesn't support (yet) the special case when Laps are added on a second parsing run while the results (MIRs or MRRs)
    # are already present on the DB but not yet re-mapped inside the MacroSolver data cache!
    # (MacroSolver has a #map_events_from_db() and #map_programs_from_db() but it doesn't have a
    #  "map_results_from_db" method -- yet.)
    # In other words, this assumes all results and laps come from the original JSON data file and not also from
    # pre-existing data on the DB.

    prgs_hash = @solver.rebuild_cached_entities_for('meeting_program')
    mirs_hash = @solver.rebuild_cached_entities_for('meeting_individual_result')
    laps_hash = @solver.rebuild_cached_entities_for('lap')
    # WARNING: proper relay category change/adjust is NOT currently supported! (Even in case of swimmer YOB editing!)
    # mrss_hash = @solver.rebuild_cached_entities_for('meeting_relay_swimmer')

    # There's nothing to move if the MPrgs haven't been mapped yet:
    return if prgs_hash.blank?

    mirs_hash.select { |key, _ent| key.include?(swimmer_key) }.each_value do |mir_entity|
      update_mprogram_bindings_for_entity(
        prgs_hash:, entity: mir_entity, category_code: cat_code, category_type_id: category_type.id,
        gender_code:, gender_type_id: updated_attrs['gender_type_id'].to_i
      )
    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # For each Lap that includes this same swimmer, move it to the correct MPrg (MIR should be alread fixed at this point)
    laps_hash.select { |key, _ent| key.include?(swimmer_key) }.each_value do |lap_entity|
      update_mprogram_bindings_for_entity(
        prgs_hash:, entity: lap_entity, category_code: cat_code, category_type_id: category_type.id,
        gender_code:, gender_type_id: updated_attrs['gender_type_id'].to_i
      )
    end

    # WARNING: proper relay category change/adjust is NOT currently supported! (Even in case of swimmer YOB editing!)

    # Same as above, with the exception that we don't need to update the RelayLap entities
    # (The only bindings for RelayLap are MRS & MRR but no MPrg)
    # mrss_hash.select { |key, _ent| key.include?(swimmer_key) }.each_value do |mrs_entity|
    #   update_mprogram_bindings_for_entity(
    #     prgs_hash:, entity: mrs_entity, category_code: cat_code, category_type_id: category_type.id,
    #     gender_code:, gender_type_id: updated_attrs['gender_type_id'].to_i
    #   )
    # end
  end
  #-- -------------------------------------------------------------------------
  #++

  # Updates the MeetingProgram bindings for a given Import::Entity adding a new MeetingProgram to the @solver data cache
  # when not found.
  # The method updates directly the Entity reference's bindings with the new target MeetingProgram, given
  # the new values for category & gender.
  #
  # WARNING: the implementation doesn't take into account relay category change (even on swimmer YOB change)
  #          => DO NOT USE THIS TO MOVE/UPDATE MRS BINDINGS TO MPRGS! <=
  #
  # == Options:
  # - <tt>:prgs_hash</tt>         => MeetingProgram entities hash, having format {mprg_key => mprg_entity};
  # - <tt>:entity</tt>            => the ImportEntity for which the MeetingPrograms bindings have to be updated;
  # - <tt>:category_code</tt>     => the new category code (CategoryType#code);
  # - <tt>:category_type_id</tt>  => the new category type id (CategoryType#id);
  # - <tt>:gender_code</tt>       => the new gender type code (GenderType#code);
  # - <tt>:gender_type_id</tt>    => the new gender type id (GenderType#id);
  #
  def update_mprogram_bindings_for_entity(options = {}) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    prgs_hash = options&.fetch(:prgs_hash, {})
    entity = options&.fetch(:entity, nil)
    category_code = options&.fetch(:category_code, nil)
    category_type_id = options&.fetch(:category_type_id, nil)
    gender_code = options&.fetch(:gender_code, nil)
    gender_type_id = options&.fetch(:gender_type_id, nil)
    return if entity.blank? || !entity.is_a?(Import::Entity) || prgs_hash.blank? || !prgs_hash.is_a?(Hash) ||
              category_code.blank? || category_type_id.blank? || gender_code.blank? || gender_type_id.blank?

    # 1. Prepare target MPrg key
    prg_key = entity.bindings&.fetch('meeting_program', '')
    new_prg_key = "#{prg_key.split(/-M\d{2,3}-/i).first}-#{category_code}-#{gender_code}"
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # 1.1 Add the target MPrg when not found yet in the solver cache:
    unless @solver.entity_present?('meeting_program', new_prg_key)
      # Use the original MPrg as base for the new one and update the changed fields:
      prg_entity = prgs_hash&.fetch(prg_key, nil)
      new_row = prg_entity.row.dup
      new_row.event_order += 1 # (don't care if 2 MPrgs have the same order as they will be ordered also by category & gender)
      new_row.gender_type_id = gender_type_id
      new_row.category_type_id = category_type_id
      new_prg_entity = Import::Entity.new(row: new_row, matches: [], bindings: prg_entity.bindings.dup)
      @solver.add_entity_with_key('meeting_program', new_prg_key, new_prg_entity)
    end

    # 2. Move entity to the correct MPrg:
    entity.bindings['meeting_program'] = new_prg_key
    # 3. Adjust the ranks for both the old & new MPrgs:
    @solver.recompute_ranks_for(prg_key)
    @solver.recompute_ranks_for(new_prg_key)
  end
  #-- -------------------------------------------------------------------------
  #++
end
# rubocop:enable Metrics/ClassLength
