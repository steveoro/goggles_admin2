# frozen_string_literal: true

# = API Meetings Controller
#
# Manage Meetings via API.
#
class APIMeetingsController < ApplicationController
  # GET /api_meetings
  # Show the Meetings dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  # rubocop:disable Metrics/AbcSize
  def index
    result = APIProxy.call(
      method: :get, url: 'meetings', jwt: current_user.jwt,
      params: {
        name: index_params[:name],
        description: index_params[:description],
        # FIXME: 'code' is ambiguous in the current API query
        # code: index_params[:code],
        header_date: index_params[:header_date],
        header_year: index_params[:header_year],
        season_id: index_params[:season_id],
        page: index_params[:page], per_page: index_params[:per_page] || 25
      }
    )
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(MeetingsGrid, GogglesDb::Meeting, result.headers, parsed_response)

    respond_to do |format|
      @grid = MeetingsGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-meetings-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  # rubocop:enable Metrics/AbcSize
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_meeting/:id
  # Updates a single GogglesDb::Meeting row.
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
      url: "meeting/#{edit_params(GogglesDb::Meeting)['id']}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::Meeting)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to(api_meetings_path(index_params))
  end

  # POST /api_meetings/clone (:id)
  # Clones an existing GogglesDb::Meeting row, duplicating all its structure (sessions, events & programs)
  # into a new one with a subsequent edition number.
  # Requires just the meeting :id.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be cloned
  #
  def clone
    result = APIProxy.call(
      method: :post,
      url: "meeting/clone/#{edit_params(GogglesDb::Meeting)['id']}",
      jwt: current_user.jwt
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result.code)
    end
    redirect_to(api_meetings_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  # GET /api_meetings/no_mirs
  # Export all Meetings on localhost that have a zero MIR count as a CSV file.
  #
  def no_mirs # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    # Compose filtered domain for localhost:
    domain = GogglesDb::Meeting
    domain = domain.where('meetings.description LIKE ?', "%#{pass_through_params[:name]}%") if pass_through_params[:name].present?
    domain = domain.where(header_date: pass_through_params[:header_date]) if pass_through_params[:header_date].present?
    domain = domain.where(header_year: pass_through_params[:header_year]) if pass_through_params[:header_year].present?
    domain = domain.joins(:season).includes(:season).where('seasons.id': pass_through_params[:season_id]) if pass_through_params[:season_id].present?

    zero_mir_ids = domain.left_joins(:meeting_individual_results)
                         .group('meetings.id')
                         .count('meeting_individual_results.id')
                         .reject { |_id, mir_count| mir_count.positive? }.keys
    filtered_data_list = GogglesDb::Meeting.where(id: zero_mir_ids).map { |meeting| meeting_to_csv(meeting) }

    send_data(
      ([meeting_csv_header] + filtered_data_list).join("\r\n"),
      type: 'text/csv',
      disposition: 'inline',
      filename: "#{DateTime.now.strftime('%Y%m%d')}-#{pass_through_params[:season_id]}-0MIR-meetings.csv"
    )
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:meetings_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:meetings_grid)
  end

  # Default whitelist for parameters exploiting index grid params just in pass-through mode
  def pass_through_params
    params.permit(:name, :header_date, :header_year, :name, :season_id)
  end

  private

  # Returns the meeting list CSV header as a string (','-separated).
  def meeting_csv_header
    'id,date,isCancelled,name,year,meetingUrl,seasonId,manifestUrl'
  end

  # Returns a CSV string (','-separated) assuming +meeting+ is a valid GogglesDb::Meeting instance.
  def meeting_to_csv(meeting)
    "#{meeting.id},#{meeting.header_date},#{meeting.cancelled},#{meeting.description.delete(',')}," \
      "#{meeting.header_year},#{meeting.calendar&.results_link},#{meeting.season.id}," \
      "#{meeting.calendar&.manifest_link}"
  end
end
