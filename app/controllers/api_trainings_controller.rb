# frozen_string_literal: true

# = APITrainingsController
#
# Manage Creative Trainings pictures (gallery images shown by goggles_main) via API.
# Upload, edit & delete are handled one row at a time; picture attachments are
# forwarded to the API as multipart payloads.
#
class APITrainingsController < ApplicationController
  before_action :set_api_base_url, only: %i[index edit]

  # GET /api_trainings
  # Lists all the Training rows having an associated picture (plus eventually
  # stale rows with missing blobs).
  #
  # == Assigns:
  # - <tt>@rows</tt>: array of Training JSON hashes returned by the API
  # - <tt>@api_base_url</tt>: API base URL used to resolve image paths
  # - <tt>@domain_page/@domain_per_page/@domain_count</tt>: pagination data from headers
  #
  def index # rubocop:disable Metrics/AbcSize
    result = APIProxy.call(
      method: :get, url: 'trainings', jwt: current_user.jwt,
      params: { page: index_params[:page] || 1, per_page: index_params[:per_page] || 25 }
    )
    unless result.code == 200
      parsed_response = result.body.present? ? JSON.parse(result.body) : {}
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code,
                                                          error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    @rows = JSON.parse(result.body)
    @domain_page = result.headers[:page].to_i
    @domain_per_page = result.headers[:per_page].to_i
    @domain_count = result.headers[:total].to_i
  end

  # GET /api_trainings/new
  # Upload form for a new Training picture row.
  def new
    @training = { 'training_date' => Time.zone.now.strftime('%Y-%m-%dT%H:%M') }
  end
  #-- -------------------------------------------------------------------------
  #++

  # GET /api_trainings/:id/edit
  # Edit form for a single Training row.
  def edit
    @training = fetch_training(params[:id])
    if @training.blank?
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: params[:id])
      redirect_to(api_trainings_path) && return
    end

    @swimmer_label = fetch_swimmer_label(@training['swimmer_id']) if @training['swimmer_id'].present?
  end
  #-- -------------------------------------------------------------------------
  #++

  # POST /api_trainings
  # Creates a new Training row (with picture) through the API.
  def create
    result = APIProxy.call(
      method: :post, url: 'training', jwt: current_user.jwt,
      payload: training_payload
    )
    json = parse_json_result_from_create(result)

    if json.present? && json['msg'] == 'OK' && json['new'].key?('id')
      flash[:info] = I18n.t('datagrid.edit_modal.create_ok', id: json['new']['id'])
      redirect_to(api_trainings_path)
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: error_detail_for(result))
      redirect_to(new_api_training_path)
    end
  end

  # PUT /api_trainings/:id
  # Updates a single Training row. A new picture file can be (optionally) re-attached.
  def update
    result = APIProxy.call(
      method: :put,
      url: "training/#{params[:id]}",
      jwt: current_user.jwt,
      payload: training_payload
    )

    parsed_response = begin
      (result.body.present? ? JSON.parse(result.body) : {})
    rescue StandardError
      {}
    end
    if result.code == 200 && parsed_response['id'].present?
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: error_detail_for(result))
    end
    redirect_to(api_trainings_path)
  end

  # DELETE /api_trainings/:id
  # Removes a single Training row (and its attached picture).
  def destroy
    result = APIProxy.call(
      method: :delete, url: "training/#{params[:id]}", jwt: current_user.jwt
    )

    if result.body == 'true'
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: "[#{params[:id]}]")
    else
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: "[#{params[:id]}]")
    end
    redirect_to(api_trainings_path)
  end

  protected

  # Sets the API base URL used to resolve image paths in views.
  def set_api_base_url
    @api_base_url = GogglesDb::AppParameter.config.settings(:framework_urls).api
  end

  # Fetches a single Training row detail from the API.
  # Returns the parsed Hash or +nil+ when missing/not found.
  def fetch_training(row_id)
    result = APIProxy.call(
      method: :get, url: "training/#{row_id}", jwt: current_user.jwt
    )
    return unless result.code == 200 && result.body.present?

    JSON.parse(result.body).presence
  end

  # Fetches the display label for a Swimmer (used to preselect the autocomplete).
  def fetch_swimmer_label(swimmer_id)
    result = APIProxy.call(
      method: :get, url: "swimmer/#{swimmer_id}", jwt: current_user.jwt
    )
    return unless result.code == 200 && result.body.present?

    JSON.parse(result.body)['complete_name']
  end

  # Whitelisted params for create/update; the picture file is sent as 'image'.
  # An empty file input (no file selected) is stripped so the API won't try to
  # re-attach a missing picture on update.
  def training_payload
    permitted = params.expect(
      training: %i[image training_by created_by training_date description]
    ).to_h
    # (the swimmer autocomplete combo-box posts its hidden ID as a top-level param)
    permitted['swimmer_id'] = params[:swimmer_id]
    permitted.delete('image') if permitted['image'].blank?
    permitted.compact
  end

  # Strong parameters checking for /index.
  def index_params
    params.permit(:page, :per_page)
  end

  # Extracts the most useful error detail from an API result.
  def error_detail_for(result)
    JSON.parse(result.body)['error']
  rescue StandardError
    result.body.presence || result.code
  end
end
