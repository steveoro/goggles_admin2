# frozen_string_literal: true

# = GogglesCupController
#
# Season-first GogglesCup configuration & management UI:
#
# - GET index: pick a championship year (seasons having a cup + current year),
#   a primary team (defaulted from the user's managed affiliations / badge) and
#   an existing cup for that team & year, or start a new one.
# - The swimmer list is always rendered when a team is resolved; it merges the
#   result rows of the shown championship year with the MASFIN badges of the
#   current & previous championship year (GogglesDb::GogglesCup::SwimmerOptionsQuery).
# - When the selected cup has a stored ranking (ranking_data present), the list
#   is rendered read-only and an edit button (POST clear_ranking) allows
#   clearing the stored values to change the selection.
# - Compute/serialization honor the cup's season_year as the ranking base year
#   (the +@base_year+ session variable driving the Scenic views is set around
#   the action and always reset afterwards).
#
class GogglesCupController < ApplicationController
  before_action :authenticate_user!
  before_action :set_goggle_cup, only: %i[index compute save clear_ranking apply_local resync publish unpublish base_timings]
  before_action :set_season_year, only: %i[index]
  before_action :set_team,
                only: %i[index smart_selection compute save clear_ranking apply_local resync publish unpublish base_timings]
  before_action :set_secondary_team, only: %i[index compute]
  before_action :set_selected_swimmer_ids, only: %i[compute]
  before_action :set_no_duplicated_events, only: %i[compute]
  around_action :with_base_year, only: %i[index smart_selection compute]

  # [GET] Renders the GogglesCup selection/configuration page.
  def index
    prepare_page_context
    @ranking_data = @readonly ? GogglesDb::GoggleCupRanking::DataDeserializer.new(@goggle_cup).call : []
  end

  # [GET] Returns smart-selected swimmer ids for the secondary team filter.
  def smart_selection
    selected_ids = @team ? swimmer_options_query.smart_selected_ids_for(params[:secondary_team_id]) : []

    render json: { swimmer_ids: selected_ids }
  end

  # [POST] Creates or updates the cup configuration on the REMOTE database via
  # the GoggleCupManage API (missing badges are provisioned remotely as well),
  # then mirrors the returned row (+ badges + affiliation) into the local DB.
  def save
    result = remote_save
    unless api_success?(result)
      flash[:alert] = t('goggles_cup.cup_save_error', errors: result.error_detail)
      return redirect_to(goggles_cup_preview_path(back_params))
    end

    cup = sync_to_local(result)
    flash[:notice] = saved_notice(result.json['badges_report']) if cup
    redirect_to(goggles_cup_preview_path(back_params(goggle_cup_id: cup&.id || result.json.dig('cup', 'id'))))
  end

  # [POST] Clears the stored ranking_data of the selected cup on the remote DB
  # (then resyncs the local mirror) so its swimmer selection becomes editable
  # again. Redirects back to the (editable) page.
  def clear_ranking
    return redirect_cup_required if @goggle_cup.blank?

    if @goggle_cup.ranking_data.present?
      result = cup_api_call(:post, "goggle_cup_manage/#{@goggle_cup.id}/clear_ranking")
      if api_success?(result)
        flash[:notice] = t('goggles_cup.ranking_cleared') if sync_to_local(result)
      else
        flash[:alert] = t('goggles_cup.api_error', message: result.error_detail)
      end
    end

    redirect_to(goggles_cup_preview_path(back_params))
  end

  # [POST] "Apply changes locally": pulls the remote cup row (+ provisioned
  # badges) via GET /goggle_cup_manage/:id/sync and overwrites the local mirror.
  def apply_local
    return if sync_from_remote!(t('goggles_cup.apply_local_success')) == :cup_required

    redirect_to(goggles_cup_preview_path(back_params))
  end

  # [POST] Manual resync of the local mirror before edits (same pull as
  # #apply_local): lets the operator refresh the row a remote team manager may
  # have changed in the meantime.
  def resync
    return if sync_from_remote!(t('goggles_cup.resync_success')) == :cup_required

    redirect_to(goggles_cup_preview_path(back_params))
  end

  # [POST] Publishes the cup on the remote DB (resetting any other published
  # cup for the same team & year), then resyncs the local mirror.
  def publish
    remote_toggle(:publish)
  end

  # [POST] Un-publishes the cup on the remote DB, then resyncs the local mirror.
  def unpublish
    remote_toggle(:unpublish)
  end

  # [POST/GET] Computes the GogglesCup ranking for the selected swimmers and renders
  # it in HTML, JSON, CSV, XLSX or PDF formats.
  # Only a POST (the Compute button) on a saved cup runs the persisted remote
  # computation (then resyncs the local mirror). Exports (GET csv/xlsx/pdf links)
  # never write remotely: they use the stored ranking of a read-only cup, or a
  # local preview computation otherwise. Unsaved cups always get a local preview.
  def compute
    prepare_page_context
    @ranking_visible = true

    if export_request?
      @ranking_data = export_ranking_data
    elsif request.post? && @goggle_cup&.persisted?
      error = compute_remotely
      return respond_with_compute_error(error) if error
    else
      @ranking_data = ranking_data
    end

    respond_to do |format|
      format.html { render(:index) }
      format.json { render json: { html: ranking_html } }
      format.csv { send_ranking_export(format: :csv) }
      format.xlsx { send_ranking_export(format: :xlsx) }
      format.pdf { send_ranking_export(format: :pdf) }
    end
  end

  # [GET] Renders a dedicated HTML page with the base timings for a stored cup.
  def base_timings
    return redirect_invalid_export if @team.blank? || @goggle_cup.blank? || @goggle_cup.ranking_data.blank?

    @ranking_data = GogglesDb::GoggleCupRanking::DataDeserializer.new(@goggle_cup).call
    @no_duplicated_events = no_duplicated_from(@goggle_cup)
  end

  private

  # Sets @goggle_cup from :goggle_cup_id. The cup, when present, is authoritative
  # for both the team and the season year of the page.
  def set_goggle_cup
    @goggle_cup ||= GogglesDb::GoggleCup.find_by(id: params[:goggle_cup_id]) if params[:goggle_cup_id].present?
  end

  # Sets @season_year: the selected cup's year, the explicit parameter, or the
  # current MASFIN championship year as fallback.
  def set_season_year
    return if @season_year.present?

    @season_year = @goggle_cup&.season_year ||
                   params[:season_year].presence&.to_i ||
                   default_season_year
  end

  # Returns the championship year of the ongoing (or latest upcoming) MASFIN
  # season -- the domain reference year for GoggleCups.
  def default_season_year
    @default_season_year ||= GogglesDb::Season.current_championship_year(GogglesDb::SeasonType.mas_fin)
  end

  # Sets @team: the cup's team, the explicit :team_id parameter, or (on the index
  # page only) the default team resolved for the current user.
  def set_team
    @team = @goggle_cup&.team
    @team ||= GogglesDb::Team.find_by(id: params[:team_id]) if params[:team_id].present?
    @team ||= team_resolver.default_team if action_name == 'index'
    @team_id = @team&.id || params[:team_id]
  end

  def team_resolver
    @team_resolver ||= GogglesDb::GogglesCup::ManagedTeamResolver.new(user: current_user, season_year: @season_year)
  end

  def set_secondary_team
    @secondary_team_id = params[:secondary_team_id]
    @secondary_team = GogglesDb::Team.find_by(id: @secondary_team_id) if @secondary_team_id.present?
  end

  def set_selected_swimmer_ids
    @selected_swimmer_ids = Array(params[:swimmer_ids]).compact_blank
  end

  def set_no_duplicated_events
    @no_duplicated_events = ActiveModel::Type::Boolean.new.cast(params[:no_duplicated_events])
  end

  # Sets the +@base_year+ session variable used by the parameterized Scenic views
  # to the championship year being displayed, then always resets it so the
  # override cannot leak into other requests on the same pooled connection.
  # NOTE: around filters wrap the whole action chain, so the cup/season context
  # must be resolved here (the declared before_actions will then no-op inside).
  def with_base_year
    set_goggle_cup
    set_season_year
    GogglesDb::AbstractBestResult.with_base_year(@season_year)
    yield
  ensure
    GogglesDb::AbstractBestResult.with_base_year(nil)
  end

  # Prepares all the shared instance variables used by the index view (also
  # reused by the HTML format of #compute).
  def prepare_page_context
    @team_resolver = team_resolver
    @season_years = available_season_years
    @goggle_cups = @team ? GogglesDb::GoggleCup.where(team_id: @team.id, season_year: @season_year).order(:description) : []
    @swimmers_for_team = swimmers_for_team
    @external_swimmers = external_swimmers_for(@goggle_cup)
    @readonly = @goggle_cup&.ranking_data.present?
    @exportable = @goggle_cup&.persisted? && @goggle_cup.swimmers_ids.present?
    @selected_swimmer_ids = effective_swimmer_ids
    @no_duplicated_events = effective_no_duplicated_events
    @ranking_visible = false if @ranking_visible.nil?
  end

  # On #compute the ivar is always defined (empty => user unchecked everything);
  # on #index it is read back from the stored configuration instead.
  def effective_swimmer_ids
    return Array(@selected_swimmer_ids) if instance_variable_defined?(:@selected_swimmer_ids)

    (@goggle_cup&.swimmer_ids_array || []).map(&:to_s)
  end

  # On #compute the flag ivar is always defined (nil => user unchecked it);
  # on #index it is read back from the stored ranking_data instead.
  def effective_no_duplicated_events
    return @no_duplicated_events == true if instance_variable_defined?(:@no_duplicated_events)

    no_duplicated_from(@goggle_cup)
  end

  # Distinct championship years having at least one cup for the manageable team
  # domain (all cups for admins), always including the currently shown year and
  # the current MASFIN championship year (so a new cup can be started for it
  # even while browsing another year).
  def available_season_years
    scope = if team_resolver.can_choose_any_team?
              GogglesDb::GoggleCup.all
            else
              GogglesDb::GoggleCup.where(team_id: team_resolver.managed_team_ids)
            end
    (scope.distinct.pluck(:season_year) + [@season_year, default_season_year]).compact.uniq.sort.reverse
  end

  def swimmers_for_team
    return [] unless @team

    swimmer_options_query.call
  end

  def swimmer_options_query
    @swimmer_options_query ||= GogglesDb::GogglesCup::SwimmerOptionsQuery.new(team_id: @team_id, base_year: @season_year)
  end

  def ranking_data
    return [] unless @team

    if @selected_swimmer_ids.present?
      GogglesDb::GogglesCup::RankingCalculator.new(
        team_id: @team_id,
        swimmer_ids: @selected_swimmer_ids,
        no_duplicated_events: @no_duplicated_events
      ).call
    elsif @goggle_cup&.ranking_data.present?
      GogglesDb::GoggleCupRanking::DataDeserializer.new(@goggle_cup).call
    else
      []
    end
  end

  # === Remote write path (GoggleCupManage API) ==============================

  # Wraps APIProxy with the current admin's JWT; +path+ is the endpoint suffix
  # inside /api/v3 (e.g. "goggle_cup_manage/12/sync").
  # Network failures (API down, timeouts) yield a failed result instead of raising.
  def cup_api_call(method, path, payload: nil)
    result = APIProxy.call(method:, url: path, payload:, jwt: current_user.jwt)
    # (APIProxy wraps timeouts, which carry no response, into an empty Result)
    result.__getobj__.nil? ? unreachable_api_result : result
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, RestClient::Exception => e
    unreachable_api_result(e.message)
  end

  UnreachableApiResult = Struct.new(:error_detail) do
    def code = 0
    def json = { 'error' => error_detail }
  end

  def unreachable_api_result(detail = nil)
    UnreachableApiResult.new(t('goggles_cup.api_unreachable', detail: detail.to_s))
  end

  def api_success?(result)
    (200..299).cover?(result.code)
  end

  # Mirrors the +sync+ block of a successful API response into the local DB.
  # The remote change is already applied at this point: on a local failure the
  # admin gets an alert suggesting a resync instead of a 500.
  # Returns the local cup, or +nil+ on failure.
  def sync_to_local(result)
    SyncCupToLocal.call(result.json['sync'] || result.json)
  rescue ActiveRecord::ActiveRecordError => e
    flash[:alert] = t('goggles_cup.local_sync_error', message: e.message.truncate(200))
    nil
  end

  # Remote save: PUT for an existing cup (falling back to POST when the remote
  # row doesn't exist -- e.g. a cup created locally before the API path), POST
  # for a new one.
  def remote_save
    return cup_api_call(:post, 'goggle_cup_manage', payload: cup_save_payload) if @goggle_cup.blank?

    result = cup_api_call(:put, "goggle_cup_manage/#{@goggle_cup.id}", payload: cup_save_payload)
    result = cup_api_call(:post, 'goggle_cup_manage', payload: cup_save_payload) if result.code == 404
    result
  end

  def cup_save_payload
    {
      team_id: @team_id || params[:team_id],
      season_year: params[:season_year],
      description: params[:description],
      name: params[:name].presence,
      end_date: params[:end_date],
      swimmer_ids: Array(params[:swimmer_ids]).compact_blank.map(&:to_i)
    }
  end

  # Pulls the remote row (+ badges) and overwrites the local mirror.
  # Returns :cup_required when no cup is selected (redirect already sent).
  def sync_from_remote!(success_notice)
    if @goggle_cup.blank?
      redirect_cup_required
      return :cup_required
    end

    result = cup_api_call(:get, "goggle_cup_manage/#{@goggle_cup.id}/sync")
    if api_success?(result)
      flash[:notice] = success_notice if sync_to_local(result)
    else
      flash[:alert] = t('goggles_cup.api_error', message: result.error_detail)
    end
  end

  def remote_toggle(action)
    return redirect_cup_required if @goggle_cup.blank?

    result = cup_api_call(:post, "goggle_cup_manage/#{@goggle_cup.id}/#{action}")
    if api_success?(result)
      flash[:notice] = t("goggles_cup.#{action}_success") if sync_to_local(result)
    else
      flash[:alert] = t('goggles_cup.api_error', message: result.error_detail)
    end

    redirect_to(goggles_cup_preview_path(back_params))
  end

  # Remote compute: persists the ranking on the API, resyncs the local mirror
  # and exposes the deserialized entries for rendering.
  # Returns +nil+ on success, or the error message.
  def compute_remotely
    result = cup_api_call(
      :post, "goggle_cup_manage/#{@goggle_cup.id}/compute",
      payload: { swimmer_ids: @selected_swimmer_ids.map(&:to_i), no_duplicated_events: @no_duplicated_events }
    )
    return t('goggles_cup.compute_error', message: result.error_detail) unless api_success?(result)
    return flash.delete(:alert) unless sync_to_local(result)

    @goggle_cup.reload
    @ranking_data = GogglesDb::GoggleCupRanking::DataDeserializer.new(@goggle_cup).call
    nil
  end

  # JSON error for the AJAX Compute button, flash + redirect otherwise.
  def respond_with_compute_error(message)
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_content }
      format.any do
        flash[:alert] = message
        redirect_to(goggles_cup_preview_path(back_params))
      end
    end
  end

  def export_request?
    %i[csv xlsx pdf].include?(request.format.symbol)
  end

  # Ranking for exports: the stored one for a read-only cup (with its own
  # no_duplicated_events flag), a local preview computation otherwise.
  def export_ranking_data
    return ranking_data unless @readonly

    @no_duplicated_events = no_duplicated_from(@goggle_cup)
    GogglesDb::GoggleCupRanking::DataDeserializer.new(@goggle_cup).call
  end

  # Saved-flash text, extended with the remote badge-provisioning counts.
  def saved_notice(report)
    base = t('goggles_cup.cup_saved')
    return base unless report.is_a?(Hash)

    created = report['created'].is_a?(Array) ? report['created'].size : 0
    skipped = report['skipped'].is_a?(Array) ? report['skipped'].size : 0
    return base if (created + skipped).zero?

    "#{base} #{t('goggles_cup.badges_report', created:, skipped:)}"
  end

  def redirect_cup_required
    flash[:alert] = t('goggles_cup.errors.cup_required')
    redirect_to(goggles_cup_preview_path(back_params))
  end

  def back_params(overrides = {})
    { goggle_cup_id: @goggle_cup&.id, season_year: params[:season_year],
      team_id: params[:team_id] }.merge(overrides)
  end

  def external_swimmers_for(cup)
    return [] unless cup && cup.swimmers_ids.present?

    team_swimmer_ids = swimmer_options_query.call.pluck(:swimmer_id)
    cup_ids = cup.swimmer_ids_array
    external_ids = cup_ids - team_swimmer_ids
    return [] if external_ids.blank?

    GogglesDb::Swimmer.where(id: external_ids)
                      .pluck(:id, :complete_name, :year_of_birth)
                      .map { |r| { swimmer_id: r[0], swimmer_name: r[1], swimmer_year_of_birth: r[2] } }
  end

  def no_duplicated_from(cup)
    return false if cup&.ranking_data.blank?

    data = cup.ranking_data.is_a?(String) ? JSON.parse(cup.ranking_data) : cup.ranking_data
    value = data['no_duplicated_events']
    value.nil? ? false : value
  rescue StandardError
    false
  end

  def ranking_html
    render_to_string(
      partial: 'goggles_cup/ranking',
      formats: [:html],
      locals: {
        team: @team,
        ranking_data: @ranking_data,
        selected_swimmer_ids: @selected_swimmer_ids,
        secondary_team_id: @secondary_team_id,
        no_duplicated_events: @no_duplicated_events,
        goggle_cup: @goggle_cup
      }
    )
  end

  # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def send_ranking_export(format:)
    return redirect_invalid_export unless @team && @ranking_data.present?

    result = GogglesDb::GoggleCupRanking::Exporter.new(
      cup: @goggle_cup, team: @team, ranking_data: @ranking_data,
      no_duplicated_events: @no_duplicated_events,
      description: @goggle_cup&.description.presence || params[:description],
      season_year: @goggle_cup&.season_year || params[:season_year]&.to_i
    ).export(format_name: format, export_type: params[:export_type])

    return redirect_invalid_export if result.blank?

    send_data(result[:data], filename: result[:filename], type: result[:mime_type], disposition: 'attachment')
  end

  def redirect_invalid_export
    flash[:alert] = I18n.t('goggles_cup.errors.invalid_selection_or_data')
    redirect_to(goggles_cup_preview_path(goggle_cup_id: @goggle_cup&.id, season_year: params[:season_year],
                                         team_id: params[:team_id]))
  end
end
