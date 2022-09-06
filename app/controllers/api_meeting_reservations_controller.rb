# frozen_string_literal: true

# = MeetingReservations Controller
#
# Manage MeetingReservations via API.
#
# rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
class APIMeetingReservationsController < ApplicationController
  # GET /api_meeting_reservations
  # Show the MeetingReservations dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    result = APIProxy.call(
      method: :get, url: 'meeting_reservations', jwt: current_user.jwt,
      params: {
        meeting_id: index_params[:meeting_id],
        team_id: index_params[:team_id],
        swimmer_id: index_params[:swimmer_id],
        badge_id: index_params[:badge_id],
        not_coming: index_params[:not_coming],
        confirmed: index_params[:confirmed],
        page: index_params[:page], per_page: index_params[:per_page]
      }
    )
    parsed_response = JSON.parse(result.body)
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(MeetingReservationsGrid, GogglesDb::MeetingReservation, result.headers, parsed_response)

    respond_to do |format|
      @grid = MeetingReservationsGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv(
            :id, :meeting_id, :meeting_name,
            :swimmer_id, :swimmer_name,
            :team_id, :badge_id,
            :not_coming, :confirmed,
            :notes
          ),
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-meeting_reservations-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # GET /api_meeting_reservation/expand/:id
  # Retrieves the details of a single GogglesDb::MeetingReservation row and displays them
  # on 2 different grids: 1 for the events reservations found & 1 for the relay reservations.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the master instance row for which the details have to be displayed
  #
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def expand
    result = APIProxy.call(
      method: :get,
      url: "meeting_reservation/#{edit_params(GogglesDb::MeetingReservation)['id']}",
      jwt: current_user.jwt
    )
    json_domain = JSON.parse(result.body)
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: json_domain['error'])
      redirect_to(root_path) && return
    end

    # Setup grid domains:
    # (Whitelisting attributes here is needed because the json domain comes from a much-richer result,
    #  containing almost all linked subentities)
    @event_domain = json_domain['meeting_event_reservations']&.map do |attrs|
      GogglesDb::MeetingEventReservation.new(
        datagrid_model_attributes_for(GogglesDb::MeetingEventReservation, attrs)
      )
    end
    @relay_domain = json_domain['meeting_relay_reservations']&.map do |attrs|
      GogglesDb::MeetingRelayReservation.new(
        datagrid_model_attributes_for(GogglesDb::MeetingRelayReservation, attrs)
      )
    end

    # Setup datagrids:
    @swimmer_name = json_domain['swimmer']['display_label']
    @meeting_name = json_domain['meeting']['display_label']
    @team_name = json_domain['team']['display_label']
    # Define attribute values preset for the details, associated to the master row:
    @master_attributes = {
      meeting_reservation_id: json_domain['id'],
      meeting_id: json_domain['meeting_id'],
      swimmer_id: json_domain['swimmer_id'],
      team_id: json_domain['team_id'],
      badge_id: json_domain['badge_id']
    }
    MeetingEventReservationsGrid.data_domain = @event_domain.presence || []
    MeetingRelayReservationsGrid.data_domain = @relay_domain.presence || []

    respond_to do |format|
      format.html do
        @event_grid = MeetingEventReservationsGrid.new(grid_filter_params)
        @relay_grid = MeetingRelayReservationsGrid.new(grid_filter_params)
      end
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # PUT /api_meeting_reservation/:id
  # Updates a single GogglesDb::MeetingReservation row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be updated
  #
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update
    # Prepare the API payload using the proper key (namespace) & params for the sub-entity:
    details_key = if params['_model']&.include?('EventReservation')
                    'events'
                  elsif params['_model']&.include?('RelayReservation')
                    'relays'
                  end
    details_class = if params['_model']&.include?('EventReservation')
                      GogglesDb::MeetingEventReservation
                    elsif params['_model']&.include?('RelayReservation')
                      GogglesDb::MeetingRelayReservation
                    else
                      GogglesDb::MeetingReservation
                    end
    filtered_params = edit_params(details_class, details_key)
                      .to_hash
                      .reject { |key, _v| %w[_method authenticity_token].include?(key) }
    api_payload = details_key.present? ? { details_key => [filtered_params] } : filtered_params

    result = APIProxy.call(
      method: :put,
      url: "meeting_reservation/#{edit_params(GogglesDb::MeetingReservation)['id']}",
      jwt: current_user.jwt,
      payload: api_payload
    )

    # Non-standard API response due to sub-entity update:
    if result.code >= 200 && result.code < 300
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end

    # Keep row focus after update redirect by forcing pass-through of the master-row filtering:
    if details_key.present? && filtered_params.key?('meeting_reservation_id')
      redirect_to api_meeting_reservations_expand_path(id: filtered_params['meeting_reservation_id'])
    else
      redirect_to api_meeting_reservations_path(
        page: index_params[:page], per_page: index_params[:per_page],
        meeting_reservations_grid: {
          meeting_id: edit_params(GogglesDb::MeetingReservation)['meeting_id'],
          swimmer_id: edit_params(GogglesDb::MeetingReservation)['swimmer_id'],
          team_id: edit_params(GogglesDb::MeetingReservation)['team_id']
        }
      )
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # POST /api_meeting_reservations
  # Creates a new GogglesDb::MeetingReservation row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  def create
    # This endpoint uses a non-stadard API payload and creates both master & details using
    # a dedicated command. Just 2 parameters are required:
    api_payload = edit_params(GogglesDb::MeetingReservation)
                  .select { |key, _v| %w[badge_id meeting_id].include?(key) }
                  .to_hash

    result = APIProxy.call(
      method: :post,
      url: 'meeting_reservation',
      jwt: current_user.jwt,
      payload: api_payload
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    # Keep row focus after create redirect by forcing pass-through of the master-row filtering:
    redirect_to api_meeting_reservations_path(
      page: index_params[:page], per_page: index_params[:per_page],
      meeting_reservations_grid: {
        meeting_id: edit_params(GogglesDb::MeetingReservation)['meeting_id'],
        swimmer_id: edit_params(GogglesDb::MeetingReservation)['swimmer_id'],
        team_id: edit_params(GogglesDb::MeetingReservation)['team_id']
      }
    )
  end

  # DELETE /api_meeting_reservations
  # Removes GogglesDb::MeetingReservation rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: single row ID, to be used for single row deletion
  # - <tt>ids</tt>: array of row IDs, to be used for multiple rows deletion
  #
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?

    error_ids = delete_rows!('meeting_reservation', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to api_meeting_reservations_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    # Do 1 merge for each grid that may use filtering or ordering:
    @grid_filter_params = params.fetch(:meeting_reservations_grid, {}).permit!
                                .merge(params.fetch(:meeting_event_reservations_grid, {}).permit!)
                                .merge(params.fetch(:meeting_relay_reservations_grid, {}).permit!)
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(
      :page, :per_page, :meeting_reservations_grid,
      :meeting_event_reservations_grid, :meeting_relay_reservations_grid
    )
                          .merge(params.fetch(:meeting_reservations_grid, {}).permit!)
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
