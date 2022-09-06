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
        name: index_params[:description],
        date: index_params[:date],
        header_year: index_params[:header_year],
        season_id: index_params[:season_id],
        page: index_params[:page], per_page: index_params[:per_page] || 25
      }
    )
    parsed_response = JSON.parse(result.body)
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
    redirect_to api_meetings_path(page: index_params[:page], per_page: index_params[:per_page])
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
    redirect_to api_meetings_path(page: index_params[:page], per_page: index_params[:per_page])
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:meetings_grid, {}).permit!
  end

  # Strong parameters checking for /index
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    @index_params = params.permit(:page, :per_page, :meetings_grid)
                          .merge(params.fetch(:meetings_grid, {}).permit!)
  end
end
