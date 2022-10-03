# frozen_string_literal: true

# = DataFixController: pre-production editing
#
# Allows review & edit of imported or crawled data before the push to production.
# (Legacy data-import step 1 & 2)
#
class DataFixController < ApplicationController
  # Members @data_hash & @solver must be set for all actions (redirects if the JSON parsing fails)
  before_action :set_file_path, :parse_file_contents, :prepare_solver, except: :coded_name

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
    if @data_hash['meeting'].blank? || @data_hash['meeting_session'].blank? || edit_params['reparse'].present?
      @solver.map_meeting_and_sessions
      # Serialize this step overwriting the same file:
      overwrite_file_path_with_json_from(@solver.data)
    end
    prepare_sessions_and_pools_from_data_hash
    ActionCable.server.broadcast("ImportStatusChannel", msg: 'Review sessions: ready')
  end

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
    if @data_hash['team'].blank? || edit_params['reparse'].present?
      @solver.map_teams_and_swimmers
      overwrite_file_path_with_json_from(@solver.data)
    end
    @teams_hash = @solver.rebuild_cached_entities_for('team')
    ActionCable.server.broadcast("ImportStatusChannel", msg: 'Review teams: ready')
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
  def review_swimmers
    # Prepare the data review, solving the entities first if not already serialized
    # or when a reparse is requested:
    if @data_hash['swimmer'].blank? || edit_params['reparse'].present?
      @solver.map_teams_and_swimmers
      overwrite_file_path_with_json_from(@solver.data)
    end
    @swimmers_hash = @solver.rebuild_cached_entities_for('swimmer')
    ActionCable.server.broadcast("ImportStatusChannel", msg: 'Review swimmers: ready')
  end

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
    ActionCable.server.broadcast("ImportStatusChannel", msg: 'Review events: ready')
  end

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
    @prgs_keys = @data_hash['meeting_program']&.keys
    @mirs_keys = @data_hash['meeting_individual_result']&.keys
    ActionCable.server.broadcast("ImportStatusChannel", msg: 'Review results: ready')
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
  def update
    model_name = edit_params['model'].to_s
    entity_key = entity_key_for(model_name)

    # == Main entity update: ==
    updated_attrs = if model_name == 'meeting'
                      edit_params[model_name] # (Meetings don't use the entity key because they are 1 for each file)
                    else
                      edit_params[model_name]&.fetch(entity_key.to_s, nil) # (Request params multi-row index always a string)
                    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
    if updated_attrs.present?
      # Reject any patch param attribute not belonging to the destination list of actual model attributes:
      actual_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, model_name)
      # Always overwrite the fuzzy result ID column with the manual lookup result ID, which has a higher priority:
      # (i.e.: 'team_id' => team['id'])
      actual_attrs['id'] = updated_attrs["#{model_name}_id"] if updated_attrs["#{model_name}_id"].present?
      # Allow clearing of ID using zero:
      actual_attrs['id'] = nil if actual_attrs['id'] == 0 || actual_attrs['id'] == '0' # Avoid clearing if empty or present

      # Handle special cases:
      case model_name
      when 'team'
        # Avoid empty Team names:
        actual_attrs['name'] = updated_attrs['team'].present? ? updated_attrs['team'] : updated_attrs['editable_name'] unless actual_attrs['name'].present?
        # Prepend variations unless already there:
        actual_attrs['name_variations'] = "#{actual_attrs['name']};#{actual_attrs['name_variations']}" unless actual_attrs['name_variations'].include?(actual_attrs['name'])
        actual_attrs['name_variations'] = "#{actual_attrs['editable_name']};#{actual_attrs['name_variations']}" unless actual_attrs['name_variations'].include?(actual_attrs['editable_name'])
      when 'swimmer'
        # Overwrite complete name when the lookup values change:
        actual_attrs['complete_name'] = updated_attrs['swimmer'].present? ? updated_attrs['swimmer'] : "#{updated_attrs['last_name']} #{updated_attrs['first_name']}"
      end
      # DEBUG ----------------------------------------------------------------
      # binding.pry
      # ----------------------------------------------------------------------

      # === Update main entity attributes: ===
      # (index must be already set to the proper key type: nil for meetings, integer for sessions, string for others)
      if entity_key.present?
        @data_hash[model_name]&.fetch(entity_key, nil)&.fetch('row', nil)&.compact!
        @data_hash[model_name]&.fetch(entity_key, nil)&.fetch('row', nil)&.merge!(actual_attrs)
      else
        @data_hash[model_name]&.fetch('row', nil)&.compact!
        @data_hash[model_name]&.fetch('row', nil)&.merge!(actual_attrs)
      end
    end

    # == Bindings update: ==
    deep_nested_bindings = @solver.cached_instance_of(model_name, entity_key, 'bindings')
    # EXCEPTION: City is the only "complex" binding that could be sub-nested at depth > 1
    deep_nested_bindings.merge!(
      'city' => {
        edit_params['city'][entity_key.to_s]['key'] => edit_params['city'][entity_key.to_s]
      }
    ) if edit_params['city'].present? && edit_params['city'][entity_key.to_s].present? && edit_params['city'][entity_key.to_s]['key'].present?
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    deep_nested_bindings.each do |binding_model_name, binding_key|
      updated_attrs = edit_params[binding_model_name]&.fetch(entity_key.to_s, nil)
      if updated_attrs.present?
        # DEBUG ----------------------------------------------------------------
        # binding.pry
        # ----------------------------------------------------------------------
        # Handle the special case in which we want to update the key/index of a binding in the main entity:
        # (not the association column ID value itself -- currently this is implemented & supported only for
        #  the meeting events form, given that both events & sessions will typically be new & ID-less each time)
        if updated_attrs.key?('key') # (special/bespoke sub-association form field naming for binding keys)
          # DEBUG ----------------------------------------------------------------
          # binding.pry
          # ----------------------------------------------------------------------
          @data_hash[model_name]&.fetch(entity_key, nil)&.fetch('bindings', nil)&.merge!(
            # ASSERT: key is an index, not a string key
            { binding_model_name => updated_attrs['key'].to_i }
          )
        end

        # Use as association key for the binding in main entity its correct column name in main entity:
        # (For ex.: 'swimming_pool' => { 'swimming_pool_id' => 1 } instead of "'swimming_pool'['id']")
        main_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, model_name)
        nested_attrs = Import::MacroSolver.actual_attributes_for(updated_attrs, binding_model_name)

        # == Update association column in main entity: ==
        if entity_key.present?
          # i.e.: 'swimming_pool' => 0 => 'swimming_pool_id' (apply to main, i.e.: 'meeting_session')
          @data_hash[model_name]&.fetch(entity_key, nil)&.fetch('row', nil)&.compact!
          @data_hash[model_name]&.fetch(entity_key, nil)&.fetch('row', nil)&.merge!(main_attrs)
        else
          # Only 'meeting' doesn't have a key (the bindings, if any, must use it):
          @data_hash[model_name]&.fetch('row', nil)&.compact!
          @data_hash[model_name]&.fetch('row', nil)&.merge!(main_attrs)
        end
        # DEBUG ----------------------------------------------------------------
        # binding.pry
        # ----------------------------------------------------------------------

        # === Update binding entity attributes too: ===
        # i.e.: 'swimming_pool' => 0 => 'city_id' (apply to binding, i.e.: 'swimming_pool')
        # Always add the overwrite for the binding fuzzy result ID column with the manual lookup result ID:
        nested_attrs['id'] = updated_attrs["#{binding_model_name}_id"].to_i if updated_attrs["#{binding_model_name}_id"].present?
        # Allow clearing of ID using zero:
        nested_attrs['id'] = nil if nested_attrs['id'] == 0 || nested_attrs['id'] == '0' # Avoid clearing if empty or present
        # EXCEPTION: City is the only "complex" binding that could be sub-nested at depth > 1, returning a whole Hash (key + attributes)
        binding_key = binding_key.keys.first if binding_key.is_a?(Hash)
        @data_hash[binding_model_name]&.fetch(binding_key, nil)&.fetch('row', nil)&.compact!
        @data_hash[binding_model_name]&.fetch(binding_key, nil)&.fetch('row', nil)&.merge!(nested_attrs)
      end
    end
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    # == Serialization on same file: ==
    overwrite_file_path_with_json_from(@data_hash)

    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
    # Clean the referer URL from a possible reparse parameter:
    request.headers['HTTP_REFERER'].gsub('&reparse=true', '')

    # Fall back to step 1 (sessions) in case the referrer is not available:
    redirect_back(fallback_location: review_sessions_path(file_path: file_path_from_params, reparse: false))
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

  private

  # Strong parameters checking for file & edit (patch) related actions.
  def edit_params
    # Allow any sub-hash indexed with the current model name specified as a parameter:
    # (typically: 'team' => { index => { <team attributes> } })
    params.permit(
      :action, :reparse, :model, :key, :file_path,
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
    edit_params[params[:model]]&.values&.first['file_path']
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
  # Sets @data_hash with the parsed contents.
  # Redirects to #pull/index in case of errors.
  def parse_file_contents
    file_content = File.read(@file_path)
    begin
      @data_hash = JSON.parse(file_content)
    rescue StandardError
      flash[:error] = I18n.t('data_import.errors.invalid_file_content')
      redirect_to(pull_index_path) && return
    end
  end

  # Returns a valid Season assuming the specified +pathname+ contains the season ID as
  # last folder of the path (i.e.: "any/path/:season_id/any_file_name.ext")
  # Defaults to season ID 212 if no valid integer was found in the last folder of the path.
  # Sets @season with the specific Season retrieved.
  def detect_season_from_pathname(pathname)
    season_id = File.dirname(@file_path).split('/').last.to_i
    season_id = 212 unless season_id.positive?
    @season = GogglesDb::Season.find(season_id)
  end

  # Prepares the @solver instance, assuming @file_path & @data_hash have been set.
  # Sets @solver with current Solver instance.
  def prepare_solver
    detect_season_from_pathname(@file_path) # (sets @season)
    # FUTUREDEV: display progress in real time using another ActionCable channel? (or same?)
    @solver = Import::MacroSolver.new(season_id: @season.id, data_hash: @data_hash, toggle_debug: false)
  end

  # Assuming @data_hash contains already "solved" data for meeting & sessions, this sets
  # the @meeting_sessions & @swimming_pools member arrays with the current data found in the
  # Hash, building the proper corresponding models for each one.
  def prepare_sessions_and_pools_from_data_hash
    @solver.rebuild_cached_entities_for('city')
    @meeting_entity = @solver.rebuild_cached_entities_for('meeting')
    @meeting = @meeting_entity.row

    @meeting_sessions = []
    @swimming_pools = []
    @cities = []
    @city_keys = []
    # Don't consider nil results as part of the list:
    @solver.data['meeting_session'].compact.each_with_index do |_item, index|
      @meeting_sessions[index] = @solver.cached_instance_of('meeting_session', index)
      pool_key = @solver.cached_instance_of('meeting_session', index, 'bindings')&.fetch('swimming_pool', nil)
      # Get the Pool as first-class citizen of the form (for update/create):
      if pool_key.present?
        @swimming_pools[index] = @solver.cached_instance_of('swimming_pool', pool_key)
        # Get also the City as first-class citizen of the form:
        city_key = @solver.cached_instance_of('swimming_pool', pool_key, 'bindings')&.fetch('city', nil)
        if city_key.present?
          @cities[index] = @solver.cached_instance_of('city', city_key)
          @city_keys[index] = city_key
        end
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
    File.delete(@file_path) if File.exists?(@file_path)
    File.open(@file_path, 'w') { |f| f.write(data_hash.to_json) }
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
    prepare_sessions_and_pools_from_data_hash
    prepare_event_types_payload

    # Prepare the data to be reviewed, solving the entities first when not already serialized:
    # (or when a reparse is not requested)
    if @data_hash['meeting_event'].blank? || edit_params['reparse'].present?
      @solver.map_events_and_results
      overwrite_file_path_with_json_from(@solver.data)
    end
    @events_hash = @solver.rebuild_cached_entities_for('meeting_event')
  end
  #-- -------------------------------------------------------------------------
  #++
end
