# frozen_string_literal: true

# = Issues Controller
#
# Manage Issues via API.
#
class APIIssuesController < ApplicationController
  # GET /api_issues
  # Show the Issues dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    result = APIProxy.call(
      method: :get, url: 'issues', jwt: current_user.jwt,
      params: {
        user_id: index_params[:user_id],
        code: index_params[:code], status: index_params[:status],
        processable: index_params[:processable].present? || nil,
        done: index_params[:done].present? || nil,
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(IssuesGrid, GogglesDb::Issue, result.headers, parsed_response)

    respond_to do |format|
      @grid = IssuesGrid.new(
        datagrid_model_attributes_for(GogglesDb::Issue, grid_filter_params)
      )

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-iq-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end

  # POST /api_issues
  # Creates a new GogglesDb::Issue row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    result = APIProxy.call(
      method: :post,
      url: 'issue',
      jwt: current_user.jwt,
      payload: create_params(GogglesDb::Issue)
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to(api_issues_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_issue/:id
  # Updates a single GogglesDb::Issue row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be updated
  #
  def update
    result = APIProxy.call(
      method: :put,
      url: "issue/#{edit_params(GogglesDb::Issue)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Issue)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.presence || result.code)
    end
    redirect_to(api_issues_path(index_params))
  end

  # DELETE /api_issues
  # Removes GogglesDb::Issue rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('issue', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(api_issues_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # GET /api_issues/check/:id
  # Displays an issue report based on a specific GogglesDb::Issue row.
  # Automatically upgrades issue's status to 1 (review/accepted) if still 0 (new)
  #
  def check
    @issue_id = edit_params(GogglesDb::Issue)['id']
    result = APIProxy.call(method: :get, url: "issue/#{@issue_id}", jwt: current_user.jwt)
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(api_issues_path(index_params)) && return
    end

    # Auto-upgrade status to 'in review' if still zero:
    if parsed_response['status'].to_i.zero?
      result = APIProxy.call(method: :put, url: "issue/#{@issue_id}", jwt: current_user.jwt, payload: { 'status' => 1 })
      unless result.code == 200
        flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
        redirect_to(api_issues_path(index_params)) && return
      end

      parsed_response['status'] = 1
    end

    prepare_common_report_data(parsed_response)
    case @type
    when '0'
      prepare_report_data_type0
    when '1b'
      prepare_report_data_type1b
    when '1b1'
      prepare_report_data_type1b1
    when '2b1'
      prepare_report_data_type2b1
    when '3b'
      prepare_report_data_type3b
    when '3c'
      prepare_report_data_type3c
    when '5'
      prepare_report_data_type5
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # POST /api_issues/fix/:id
  # 1-click solver for the issue types that allow skipping manual intervention.
  #
  def fix
    swimmer_id = params.permit(:swimmer_id).fetch(:swimmer_id, nil)
    issue_id = edit_params(GogglesDb::Issue)['id']
    result = APIProxy.call(method: :get, url: "issue/#{issue_id}", jwt: current_user.jwt)
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(api_issues_path(index_params)) && return
    end

    # GET actual request:
    req = JSON.parse(parsed_response['req'])
    type = parsed_response['code']
    user_id = parsed_response['user_id']

    # Solve according to type (for what is feasible):
    case type
    when '0'                        # new TM
      autofix_type0(req, user_id)
    when '1b'                       # missing result
      autofix_type1b(req)
    when '1b1'                      # edit result
      autofix_type1b1(req)
    when '3b', '3c'                 # change associated swimmer
      autofix_type3(req, user_id, swimmer_id)
    when '5'                        # reactivate account
      send_email = params.permit(:send_email).fetch(:send_email, nil) == '1'
      autofix_type5(req, user_id, parsed_response['user']['name'], send_email ? parsed_response['user']['email'] : nil)
    end

    # Mark issue as solved unless any errors were already encountered:
    if flash[:error].blank?
      result = APIProxy.call(method: :put, url: "issue/#{issue_id}", jwt: current_user.jwt, payload: { 'status' => '4' })
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error']) if result.code != 200
    end
    redirect_to(api_issues_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:issues_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:issues_grid)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Strong parameters checking for /fix when issue type is '3[b|c]'
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def type3_params
    params.permit(:swimmer_id)
  end

  private

  # Strong parameter checking for /check & /fix
  def check_params
    params.permit(:id, :type, :req)
  end

  # GET parent meeting details.
  #
  # == Params:
  # - parent_meeting_class  => subject parent Meeting class name; will be used to set the same-named internal member
  # - parent_meeting_id     => the parent Meeting ID for which the details have to be retrieved
  #
  # == Sets:
  # - @parent_meeting_class => subject parent Meeting class name
  # - @parent_meeting       => subject parent Meeting attributes hash
  #
  def prepare_parent_meeting_details(parent_meeting_class, parent_meeting_id)
    @parent_meeting_class = parent_meeting_class
    result = APIProxy.call(method: :get, url: "#{parent_meeting_class.tableize.singularize}/#{parent_meeting_id}",
                           jwt: current_user.jwt)
    @parent_meeting = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
  end

  # Returns the first TeamAffiliation id found for the corresponding team_id & season_id, or
  # creates a new one if missing.
  # Returns nil in case of response errors from the API.
  def find_or_create_team_affiliation_id!(jwt, team_id, team_name, season_id)
    # Seek existing TeamAffiliation:
    result = APIProxy.call(method: :get, url: 'team_affiliations', jwt:,
                           payload: { team_id:, season_id: })
    existing_rows = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    return existing_rows.first['id'] if existing_rows.is_a?(Array) && existing_rows.first.is_a?(Hash) && existing_rows.first.key?('id')

    # Create missing row:
    payload = { team_id:, season_id:, name: team_name, number: '?' }
    result = APIProxy.call(method: :post, url: 'team_affiliation', jwt: current_user.jwt, payload:)
    new_row = parse_json_result_from_create(result)
    return new_row['new']['id'] if new_row.present? && new_row['msg'] == 'OK' && new_row['new'].key?('id')

    flash[:error] = "API: error during team_affiliation creation! (payload: #{payload.inspect})"
    nil
  end

  # Returns the first MeetingEvent *hash* found inside the rich API details from the parent meeting.
  # Returns nil otherwise.
  def find_meeting_event(_jwt, parent_meeting, event_type_id)
    meeting_event_hash = parent_meeting['meeting_events'].find { |me| me['event_type_id'] == event_type_id.to_i }
    return meeting_event_hash if meeting_event_hash.is_a?(Hash) # && existing_rows.first.is_a?(Hash) && existing_rows.first.key?('id')

    flash[:error] = "API: meeting_event hash not found in parent meeting! (event_type_id: #{event_type_id})"
    nil
  end

  # Returns the first MeetingProgram id found for the corresponding parameters, or
  # creates a new one if missing.
  # Returns nil in case of response errors from the API.
  #
  def find_or_create_meeting_program_id!(jwt, parent_meeting, meeting_event_hash, category_type_id, gender_type_id)
    # Seek existing meeting program:
    result = APIProxy.call(method: :get, url: 'meeting_programs', jwt:,
                           payload: { meeting_id: parent_meeting['id'], meeting_event_id: meeting_event_hash['id'],
                                      category_type_id:, gender_type_id: })
    existing_rows = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    return existing_rows.first['id'] if existing_rows.is_a?(Array) && existing_rows.first.is_a?(Hash) && existing_rows.first.key?('id')

    # Create missing row:
    pool_type_id = meeting_event_hash['pool_type']['id']
    event_order = GogglesDb::MeetingProgram.includes(:meeting_event, :category_type, :gender_type)
                                           .joins(:meeting_event, :category_type, :gender_type)
                                           .where(meeting_event_id: meeting_event_hash['id'],
                                                  category_type_id:,
                                                  gender_type_id:).last&.order.to_i + 1

    payload = { meeting_event_id: meeting_event_hash['id'], event_order:, pool_type_id:,
                category_type_id:, gender_type_id: }
    result = APIProxy.call(method: :post, url: 'meeting_program', jwt: current_user.jwt, payload:)
    new_row = parse_json_result_from_create(result)
    return new_row['new']['id'] if new_row.present? && new_row['msg'] == 'OK' && new_row['new'].key?('id')

    logger.error("\r\n---[E]--- API: error during meeting_program creation! (payload: #{payload.inspect})")
    flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'meeting_program creation')
    nil
  end
  #-- -------------------------------------------------------------------------
  #++

  # Prepares all common member variables shared by all issue report checks.
  #
  # == Params:
  # - parsed_response => already parsed API JSON response, storing the Issue details as an attribute Hash
  #
  # == Sets:
  # - @user               => attributes hash of the User reporting the issue
  # - @associated_swimmer => attributes hash of the User's associated Swimmer, if any
  # - @req                => attributes hash of the parsed JSON request from the issue row (Issue#req)
  # - @issue_title        => string label title of the current issue
  # - @status             => issue status code (stringified)
  # - @processable        => +true+ if the issue is still processable, +false+ otherwise
  #
  def prepare_common_report_data(parsed_response)
    # GET user details:
    result = APIProxy.call(method: :get, url: "user/#{parsed_response['user_id']}", jwt: current_user.jwt)
    @user = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }

    # GET associated swimmer details:
    if @user['swimmer_id'].present?
      result = APIProxy.call(method: :get, url: "swimmer/#{@user['swimmer_id']}", jwt: current_user.jwt)
      @associated_swimmer = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    end

    # GET actual request and issue details:
    @req = JSON.parse(parsed_response['req'])
    @issue_title = parsed_response['long_label']
    @type = parsed_response['code']
    @status = parsed_response['status']
    @processable = @status.to_i <= GogglesDb::Issue::MAX_PROCESSABLE_STATE
  end

  # Prepares member variables for issue type 0: request upgrade to team manager.
  #
  # == Uses:
  # - @req => the parsed JSON request of the issue (Issue#req)
  #
  # == Sets:
  # - @existing_tms => array of existing TeamManagers attributes (from API call)
  #
  def prepare_report_data_type0
    # GET list of existing TMs:
    result = APIProxy.call(method: :get, url: 'team_managers', jwt: current_user.jwt,
                           payload: { team_id: @req['team_id'], season_id: @req['season_id'] })
    @existing_tms = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
  end

  # Prepares member variables for issue type 1b: report missing result.
  #
  # NOTE: *** CURRENT IMPLEMENTATION ONLY WORKS FOR MEETINGS ***
  #
  # == Sets:
  # - @parent_meeting_class => subject name of the parent Meeting class
  # - @parent_meeting       => subject parent Meeting attributes hash
  # - @swimmer_category     => local copy of GogglesDb::CategoryType associated to the request swimmer_id
  # - @swimmer_badges       => list of local copy of GogglesDb::Badges associated to the request swimmer_id
  # - @existing_mirs        => array of attributes hash of all the MIRs found for the same request Meeting, event, category & gender
  # - @badge_mirs           => array of attributes hash of MIRs associated to the first badge  found for the request swimmer
  #
  def prepare_report_data_type1b
    # Sample request:
    # {"parent_meeting_id":"19540","parent_meeting_class":"Meeting",
    #  "event_type_id":"20","event_type_label":"100 RANA",
    #  "minutes":"1","seconds":"24","hundredths":"15",
    #   "swimmer_id":"142","swimmer_label":"ALLORO STEFANO (MAS, 1969)",
    #   "swimmer_complete_name":"ALLORO STEFANO","swimmer_first_name":"STEFANO","swimmer_last_name":"ALLORO",
    #   "swimmer_year_of_birth":"1969","gender_type_id":"1"}

    prepare_parent_meeting_details(@req['parent_meeting_class'], @req['parent_meeting_id']) # sets both @parent_meeting & @parent_meeting_class
    meeting_season = GogglesDb::Season.find_by(id: @parent_meeting['season_id']) if @parent_meeting['season_id'].present?
    swimmer_age = Time.zone.today.year - @req['swimmer_year_of_birth'].to_i
    if meeting_season.present?
      @swimmer_category = GogglesDb::CategoryType.for_season(meeting_season)
                                                 .where('(age_end >= ?) AND (age_begin <= ?)', swimmer_age, swimmer_age)
                                                 .individuals
                                                 .first
    end
    @swimmer_badges = GogglesDb::Badge.where(swimmer_id: @req['swimmer_id']).for_season(meeting_season) if meeting_season

    # GET list of existing MIRs:
    result = APIProxy.call(method: :get, url: 'meeting_individual_results', jwt: current_user.jwt,
                           payload: { meeting_id: @req['parent_meeting_id'], event_type_id: @req['event_type_id'],
                                      category_type_id: @swimmer_category.id, gender_type_id: @req['gender_type_id'] })
    @existing_mirs = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }

    # GET list of existing MIRs having SAME FIRST BADGE & MEETING:
    return if @swimmer_badges.blank?

    result = APIProxy.call(method: :get, url: 'meeting_individual_results', jwt: current_user.jwt,
                           payload: { meeting_id: @req['parent_meeting_id'], badge_id: @swimmer_badges.first.id })
    @badge_mirs = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
  end

  # Prepares member variables for issue type 1b1: report result mistake.
  #
  # NOTE: *** CURRENT IMPLEMENTATION ONLY WORKS FOR MEETINGS ***
  #
  # == Sets:
  # - @parent_meeting_class => subject name of the parent Meeting class
  # - @parent_meeting       => subject parent Meeting attributes hash
  # - @result_row           => attributes hash for the subject result row to be edited
  #
  def prepare_report_data_type1b1
    # Sample request:
    # {"result_id":"996858","result_class":"MeetingIndividualResult",
    #  "minutes":"1","seconds":"23","hundredths":"12"}

    # GET result row (MIR|UR) details:
    result = APIProxy.call(method: :get, url: "#{@req['result_class'].tableize.singularize}/#{@req['result_id']}",
                           jwt: current_user.jwt)
    @result_row = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    prepare_parent_meeting_details('Meeting', @result_row['meeting']['id']) # sets both @parent_meeting & @parent_meeting_class
  end

  # Prepares member variables for issue type 2b1: wrong team, swimmer or meeting attribution.
  #
  # NOTE: *** CURRENT IMPLEMENTATION ONLY WORKS FOR MEETINGS ***
  #
  def prepare_report_data_type2b1
    # GET result row (MIR|UR) details:
    result = APIProxy.call(method: :get, url: "#{@req['result_class'].tableize.singularize}/#{@req['result_id']}",
                           jwt: current_user.jwt)
    @result_row = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    prepare_parent_meeting_details('Meeting', @result_row['meeting']['id']) # sets both @parent_meeting & @parent_meeting_class

    # Retrieve locally all same-named teams & swimmers (possible alternatives):
    @same_named_swimmers = GogglesDb::Swimmer.for_name(@result_row['swimmer']['last_name'])
                                             .order(:complete_name)
                                             .limit(25)

    tokens = @result_row['team_affiliation']['name'].split
    cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Team, editable_name: @result_row['team_affiliation']['name'])
    @same_named_teams = cmd.successful? ? cmd.matches.map(&:candidate) : []
    shortened_team_name = tokens.size > 2 ? tokens[-3..].join(' ') : tokens.join(' ')
    cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::Team, editable_name: shortened_team_name)
    @same_named_teams = (@same_named_teams + cmd.matches.map(&:candidate)).uniq if cmd.successful?
  end

  # Prepares member variables for issue type 3b: change swimmer association (free select from existing swimmer).
  #
  def prepare_report_data_type3b
    # Sample request:
    # {"swimmer_id":"142","swimmer_label":"ALLORO STEFANO (MAS, 1969)","swimmer_complete_name":"ALLORO STEFANO",
    #  "swimmer_first_name":"STEFANO","swimmer_last_name":"ALLORO","swimmer_year_of_birth":"1969",
    #  "gender_type_id":"1"}

    result = APIProxy.call(method: :get, url: "swimmer/#{@req['swimmer_id']}", jwt: current_user.jwt)
    @swimmer = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    @same_named_swimmers = GogglesDb::Swimmer.for_name(@req['swimmer_last_name'])
                                             .order(:complete_name)
                                             .limit(25)
  end

  # Prepares member variables for issue type 3c: free associated swimmer details edit.
  #
  def prepare_report_data_type3c
    # Sample request:
    # {"type3c_first_name":"STEFANO","type3c_last_name":"ALLORO","type3c_year_of_birth":"1969",
    #  "type3c_gender_type_id":"1"}

    @user_named_swimmers = GogglesDb::Swimmer.for_name(@user['last_name'])
                                             .order(:complete_name)
                                             .limit(25)

    @same_named_swimmers = GogglesDb::Swimmer.for_name(@req['type3c_last_name'])
                                             .order(:complete_name)
                                             .limit(25)
  end

  # Prepares member variables for issue type 0: request upgrade to team manager.
  #
  # == Uses:
  # - @user => attributes hash of the User reporting the issue
  #
  # == Sets:
  # - @existing_issues => array of existing Issue attributes (from API call)
  #
  def prepare_report_data_type5
    # GET list of existing TMs:
    result = APIProxy.call(method: :get, url: 'issues', jwt: current_user.jwt, payload: { user_id: @user['id'] })
    @existing_issues = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
  end
  #-- -------------------------------------------------------------------------
  #++

  # Auto-fix for issue type 0: creates a managed affiliation if missing.
  #
  # == Params:
  # - req     => parsed JSON request of the issue (Issue#req)
  # - user_id => User ID of the owner of the Issue report
  #
  def autofix_type0(req, user_id)
    # Sets flash[:error] unless result is ok:
    target_id = find_or_create_team_affiliation_id!(current_user.jwt, req['team_id'].to_i,
                                                    req['team_label'], req['season_id'].to_i)
    return if target_id.blank?

    # create new TM:
    result = APIProxy.call(method: :post, url: 'team_manager', jwt: current_user.jwt,
                           payload: { user_id:, team_affiliation_id: target_id })
    new_row = parse_json_result_from_create(result)
    if new_row.present? && new_row['msg'] == 'OK' && new_row['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: new_row['new']['id'])
    else
      logger.error("\r\n---[E]--- API: error during team_manager creation! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'team_manager creation')
    end
  end

  # Auto-fix for issue type 1b: adds a missing MIR including a possibly missing MeetingProgram if missing.
  #
  # Currently, Badge & TeamAffiliation are assumed to be *already existing*.
  #
  # (MeetingEvent must always be existing as the user cannot choose to report as missing an event
  #  not already accounted for in the base structure of the Meeting.)
  #
  # == Params:
  # - req => parsed JSON request of the issue (Issue#req)
  #
  def autofix_type1b(req)
    # Sample request:
    # {"parent_meeting_id":"19540","parent_meeting_class":"Meeting",
    #  "event_type_id":"20","event_type_label":"100 RANA",
    #  "minutes":"1","seconds":"24","hundredths":"15",
    #   "swimmer_id":"142","swimmer_label":"ALLORO STEFANO (MAS, 1969)",
    #   "swimmer_complete_name":"ALLORO STEFANO","swimmer_first_name":"STEFANO","swimmer_last_name":"ALLORO",
    #   "swimmer_year_of_birth":"1969","gender_type_id":"1"}

    prepare_parent_meeting_details(req['parent_meeting_class'], req['parent_meeting_id']) # sets both @parent_meeting & @parent_meeting_class
    meeting_season = GogglesDb::Season.find_by(id: @parent_meeting['season_id']) if @parent_meeting['season_id'].present?
    swimmer_age = Time.zone.today.year - req['swimmer_year_of_birth'].to_i
    if meeting_season.present?
      swimmer_category = GogglesDb::CategoryType.for_season(meeting_season)
                                                .where('(age_end >= ?) AND (age_begin <= ?)', swimmer_age, swimmer_age)
                                                .individuals
                                                .first
    end
    swimmer_badges = GogglesDb::Badge.where(swimmer_id: req['swimmer_id']).for_season(meeting_season) if meeting_season
    # ASSUMES: at least a badge must be existing; ==> only the first one will be chosen <==
    if swimmer_badges.blank?
      flash[:error] = "NO badges found for swimmer_id #{req['swimmer_id']}!"
      return
    end

    # Sets flash[:error] unless result is ok:
    meeting_event = find_meeting_event(current_user.jwt, @parent_meeting, req['event_type_id'])
    return if meeting_event.blank?

    # Sets flash[:error] unless result is ok:
    meeting_program_id = find_or_create_meeting_program_id!(current_user.jwt, @parent_meeting, meeting_event,
                                                            swimmer_category.id, req['gender_type_id'])
    return if meeting_program_id.blank?

    # Create missing MIR using the first badge found:
    badge = swimmer_badges.first
    # Auto-compute new rank:
    new_timing = Timing.new(minutes: req['minutes'], seconds: req['seconds'], hundredths: req['hundredths'])
    timings = GogglesDb::MeetingIndividualResult.where(meeting_program_id:).map(&:to_timing)
    new_rank = 0
    timings.each_with_index do |timing, idx|
      new_rank = idx + 1
      break if timing > new_timing
    end

    payload = {
      meeting_program_id:, team_affiliation_id: badge.team_affiliation_id,
      team_id: badge.team_id, swimmer_id: badge.swimmer_id, badge_id: badge.id,
      minutes: req['minutes'], seconds: req['seconds'], hundredths: req['hundredths'],
      rank: new_rank
    }
    result = APIProxy.call(method: :post, url: 'meeting_individual_result', jwt: current_user.jwt, payload:)
    new_row = parse_json_result_from_create(result)

    if new_row.present? && new_row['msg'] == 'OK' && new_row['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: new_row['new']['id'])
    else
      logger.error("\r\n---[E]--- API: error during meeting_individual_result creation! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'meeting_individual_result creation')
    end
  end

  # Auto-fix for issue type 1b1: edit an existing MIR.
  #
  # == Params:
  # - req => parsed JSON request of the issue (Issue#req)
  #
  def autofix_type1b1(req)
    # Sample request:
    # {"result_id":"996858","result_class":"MeetingIndividualResult", "minutes":"1","seconds":"23","hundredths":"12"}

    # EDIT result row (MIR|UR) details:
    payload = { minutes: req['minutes'], seconds: req['seconds'], hundredths: req['hundredths'] }
    result = APIProxy.call(method: :put, url: "#{req['result_class'].tableize.singularize}/#{req['result_id']}",
                           jwt: current_user.jwt, payload:)
    if result.code == 200
      flash[:info] = I18n.t('issues.msgs.update_ok')
    else
      logger.error("\r\n---[E]--- API: error during meeting_individual_result update! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'meeting_individual_result update')
    end
  end

  # Auto-fix for issue type 3b & 3c: change swimmer association.
  #
  # == Params:
  # - req         => parsed JSON request of the issue (Issue#req)
  # - user_id     => User ID of the owner of the Issue report
  # - swimmer_id  => existing Swimmer ID for the association; force this to 0 to use the type '3c' parameters
  #                  to force new Swimmer creation
  #
  def autofix_type3(req, user_id, swimmer_id)
    # Sample request '3b':
    # {"swimmer_id":"142","swimmer_label":"ALLORO STEFANO (MAS, 1969)",
    #  "swimmer_complete_name":"ALLORO STEFANO","swimmer_first_name":"STEFANO","swimmer_last_name":"ALLORO",
    #  "swimmer_year_of_birth":"1969","gender_type_id":"1"}
    #
    # Sample request '3c:
    # {"type3c_first_name":"STEFANO","type3c_last_name":"ALLORO","type3c_year_of_birth":"1969",
    #  "type3c_gender_type_id":"1"}

    # Force/create a new swimmer:
    if swimmer_id.to_i.zero? && req['type3c_first_name'].present? && req['type3c_last_name'].present? &&
       req['type3c_year_of_birth'].present? && req['type3c_gender_type_id'].present?
      payload = { complete_name: "#{req['type3c_last_name']} #{req['type3c_first_name']}",
                  first_name: req['type3c_first_name'], last_name: req['type3c_last_name'],
                  year_of_birth: req['type3c_year_of_birth'].to_i, gender_type_id: req['type3c_gender_type_id'].to_i }
      result = APIProxy.call(method: :post, url: 'swimmer', jwt: current_user.jwt, payload:)
      new_row = parse_json_result_from_create(result)
      if new_row.present? && new_row['msg'] == 'OK' && new_row['new'].key?('id')
        flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: new_row['new']['id']) + '<br/>'.html_safe
        swimmer_id = new_row['new']['id']
      else
        logger.error("\r\n---[E]--- API: error during swimmer creation! (payload: #{payload.inspect})")
        flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'swimmer creation')
        return
      end
    end

    payload = { swimmer_id: swimmer_id.to_i }
    result = APIProxy.call(method: :put, url: "user/#{user_id}", jwt: current_user.jwt, payload:)
    if result.code != 200
      logger.error("\r\n---[E]--- API: error during user update! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'user update')
      return
    end

    payload = { associated_user_id: user_id.to_i }
    result = APIProxy.call(method: :put, url: "swimmer/#{swimmer_id}", jwt: current_user.jwt, payload:)
    if result.code == 200
      flash[:info] = flash[:info].to_s.html_safe + I18n.t('issues.msgs.update_ok')
    else
      logger.error("\r\n---[E]--- API: error during swimmer update! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'swimmer update')
    end
  end

  # Auto-fix for issue type 5: reactivate account if deactivated.
  #
  # == Params:
  # - req     => parsed JSON request of the issue (Issue#req)
  # - user_id => User ID of the owner of the Issue report
  # - user_id => User ID of the owner of the Issue report
  # - user_name => User name for the email msg
  # - user_email => User email; blank or nil to skip sending the email msg
  #
  def autofix_type5(_req, user_id, user_name, user_email)
    result = APIProxy.call(method: :put, url: "user/#{user_id}", jwt: current_user.jwt, payload: { active: true })

    if result.code == 200
      flash[:info] = I18n.t('issues.msgs.update_ok')
      # Send an email msg to the user if requested:
      if user_email.present?
        ApplicationMailer.generic_message(user_email:, user_name:,
                                          subject_text: I18n.t('issues.type5.email_subject'),
                                          content_body: I18n.t('issues.type5.email_body')).deliver_now
      end
    else
      logger.error("\r\n---[E]--- API: error during user reactivation! (payload: #{payload.inspect})")
      flash[:error] = t('issues.msgs.api_error_with_action', action_desc: 'user reactivation')
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
