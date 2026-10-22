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
#   current & previous championship year (GogglesCup::SwimmerOptionsQuery).
# - When the selected cup has a stored ranking (ranking_data present), the list
#   is rendered read-only and an edit button (POST clear_ranking) allows
#   clearing the stored values to change the selection.
# - Compute/serialization honor the cup's season_year as the ranking base year
#   (the +@base_year+ session variable driving the Scenic views is set around
#   the action and always reset afterwards).
#
class GogglesCupController < ApplicationController
  include FileCounter

  before_action :authenticate_user!
  before_action :set_goggle_cup, only: %i[index compute export_sql base_timings clear_ranking]
  before_action :set_season_year, only: %i[index]
  before_action :set_team, only: %i[index smart_selection compute save clear_ranking export_sql base_timings]
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

  # [POST] Creates or updates the current cup configuration.
  # Clears the stored ranking_data when the swimmer selection actually changed.
  def save
    cup = find_or_initialize_cup
    assign_cup_attributes(cup)

    if cup.save
      flash[:notice] = t('goggles_cup.cup_saved')
    else
      flash[:alert] = t('goggles_cup.cup_save_error', errors: cup.errors.full_messages.join(', '))
    end

    redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, season_year: params[:season_year], team_id: params[:team_id]))
  end

  # [POST] Clears the stored ranking_data of the selected cup so its swimmer
  # selection becomes editable again. Redirects back to the (editable) page.
  def clear_ranking
    if @goggle_cup&.ranking_data.present?
      @goggle_cup.update!(ranking_data: nil)
      flash[:notice] = t('goggles_cup.ranking_cleared')
    end

    redirect_to(goggles_cup_preview_path(goggle_cup_id: @goggle_cup&.id, season_year: params[:season_year],
                                         team_id: params[:team_id]))
  end

  # [POST] Generates a pushable SQL script for the current cup and stores it in
  # `crawler/data/results.new/goggle_cups/` for later production push.
  def export_sql # rubocop:disable Metrics/AbcSize
    cup = @goggle_cup
    if cup&.ranking_data.blank?
      flash[:alert] = t('goggles_cup.export_sql_error', message: t('goggles_cup.info.no_ranking_data'))
      redirect_to(goggles_cup_preview_path(goggle_cup_id: cup&.id, season_year: params[:season_year],
                                           team_id: params[:team_id])) && return
    end

    source_dir = Rails.root.join('crawler/data/results.new/goggle_cups')
    sent_dir = source_dir.to_s.gsub('results.new', 'results.sent')
    FileUtils.mkdir_p(source_dir)
    last_counter = compute_file_counter(source_dir, sent_dir)
    dest_file = "#{format('%04d', last_counter + 1)}-goggle_cup-#{cup.id}-#{cup.season_year}.sql"
    sql_full_path = source_dir.join(dest_file)

    sql_content = build_goggle_cup_sql(cup)
    File.write(sql_full_path, sql_content)

    flash[:notice] = t('goggles_cup.export_sql_success', file: dest_file)
    redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, season_year: params[:season_year],
                                         team_id: params[:team_id]))
  rescue StandardError => e
    flash[:alert] = t('goggles_cup.export_sql_error', message: e.message)
    redirect_to(goggles_cup_preview_path(goggle_cup_id: @goggle_cup&.id, season_year: params[:season_year],
                                         team_id: params[:team_id]))
  end

  # [POST/GET] Computes the GogglesCup ranking for the selected swimmers and renders
  # it in HTML, JSON, CSV, XLSX or PDF formats.
  def compute
    prepare_page_context
    @ranking_data = ranking_data
    @ranking_visible = true

    persist_ranking_data if @goggle_cup && @ranking_data.present? && @selected_swimmer_ids.present?

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
  # current championship year as fallback.
  def set_season_year
    return if @season_year.present?

    @season_year = @goggle_cup&.season_year ||
                   params[:season_year].presence&.to_i ||
                   GogglesDb::Season.current_championship_year
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
    @team_resolver ||= GogglesCup::ManagedTeamResolver.new(user: current_user, season_year: @season_year)
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
  # domain (all cups for admins), always including the currently shown year.
  def available_season_years
    scope = if team_resolver.can_choose_any_team?
              GogglesDb::GoggleCup.all
            else
              GogglesDb::GoggleCup.where(team_id: team_resolver.managed_team_ids)
            end
    (scope.distinct.pluck(:season_year) + [@season_year]).compact.uniq.sort.reverse
  end

  def swimmers_for_team
    return [] unless @team

    swimmer_options_query.call
  end

  def swimmer_options_query
    @swimmer_options_query ||= GogglesCup::SwimmerOptionsQuery.new(team_id: @team_id, base_year: @season_year)
  end

  def ranking_data
    return [] unless @team

    if @selected_swimmer_ids.present?
      GogglesCup::RankingCalculator.new(
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

  def persist_ranking_data
    serialized = GogglesDb::GoggleCupRanking::DataSerializer.new(
      cup: @goggle_cup,
      ranking_data: @ranking_data,
      no_duplicated_events: @no_duplicated_events
    ).call
    @goggle_cup.update!(ranking_data: serialized.to_json)
  end

  def find_or_initialize_cup
    id = params[:goggle_cup_id]
    id.present? ? GogglesDb::GoggleCup.find_by(id: id) : GogglesDb::GoggleCup.new
  end

  # Assigns the submitted configuration to +cup+, clearing its stored
  # ranking_data whenever the swimmer selection actually changed.
  def assign_cup_attributes(cup)
    previous_swimmer_ids = cup.swimmer_ids_array
    cup.assign_attributes(
      team_id: @team_id,
      description: params[:description],
      season_year: params[:season_year],
      end_date: params[:end_date],
      swimmers_ids: Array(params[:swimmer_ids]).compact_blank.map(&:to_i).join(',')
    )
    cup.ranking_data = nil if cup.ranking_data.present? && cup.swimmer_ids_array.sort != previous_swimmer_ids.sort
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

  # Builds a single MariaDB `INSERT ... ON DUPLICATE KEY UPDATE` statement for the
  # given +cup+, including the current primary key (+id+) so the remote row stays in
  # sync with the local one. The +lock_version+ column is intentionally left out: it
  # defaults to 0 on new rows and is not overwritten on existing ones. The result is
  # wrapped in a transaction by #wrap_sql_in_transaction.
  def build_goggle_cup_sql(cup)
    klass = cup.class
    con = klass.connection
    columns = []
    values = []
    updates = []
    excluded_from_update = %w[id created_at lock_version]
    timestamp_columns = %w[created_at updated_at]

    klass.column_names.each do |col|
      next if col == 'lock_version' # Handled separately / not part of the export

      columns << con.quote_column_name(col)
      values << if timestamp_columns.include?(col)
                  'NOW()'
                else
                  con.quote(cup[col])
                end
      updates << "#{con.quote_column_name(col)}=VALUES(#{con.quote_column_name(col)})" unless excluded_from_update.include?(col)
    end

    insert_sql = "INSERT INTO #{con.quote_column_name(klass.table_name)} (#{columns.join(', ')})\r\n  " \
                 "VALUES (#{values.join(', ')})\r\n  " \
                 "ON DUPLICATE KEY UPDATE #{updates.join(', ')};"
    wrap_sql_in_transaction(insert_sql)
  end

  # Wraps a single SQL statement in a simple transaction block, mirroring the pattern
  # used by Import::CategoryCloner. This ensures the statement runs atomically on the
  # remote production server when pushed through the batch_sql pipeline.
  def wrap_sql_in_transaction(statement)
    "SET AUTOCOMMIT = 0;\r\nSTART TRANSACTION;\r\n\r\n#{statement}\r\n\r\nCOMMIT;"
  end
end
