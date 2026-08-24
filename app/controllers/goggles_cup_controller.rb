# frozen_string_literal: true

# = GogglesCupController
class GogglesCupController < ApplicationController
  include FileCounter

  before_action :authenticate_user!
  before_action :set_team, only: %i[index smart_selection compute cup_data save load_ranking export_sql]
  before_action :set_secondary_team, only: %i[index compute]
  before_action :set_selected_swimmer_ids, only: %i[compute]
  before_action :set_no_duplicated_events, only: %i[compute]
  before_action :set_goggle_cup, only: %i[index compute export_sql]

  # [GET] Renders the GogglesCup preview/selection page for the selected team.
  def index
    @swimmers_for_team = swimmers_for_team
    @ranking_data = []
    @goggle_cups = @team ? GogglesDb::GoggleCup.where(team_id: @team.id).order(:season_year, :description) : []
    @external_swimmers = external_swimmers_for(@goggle_cup)
  end

  # [GET] Returns smart-selected swimmer ids for the secondary team filter.
  def smart_selection
    selected_ids = @team ? swimmer_options_query.smart_selected_ids_for(params[:secondary_team_id]) : []

    render json: { swimmer_ids: selected_ids }
  end

  # [GET] Returns the selected cup attributes and swimmer lists as JSON.
  def cup_data
    cup = GogglesDb::GoggleCup.find_by(id: params[:goggle_cup_id], team_id: @team_id)
    return render json: { error: 'Not found' }, status: :not_found unless cup

    team_swimmer_ids = swimmer_options_query.call.pluck(:swimmer_id)
    cup_swimmer_ids = cup.swimmer_ids_array
    external_ids = cup_swimmer_ids - team_swimmer_ids

    render json: {
      goggle_cup_id: cup.id,
      description: cup.description,
      season_year: cup.season_year,
      end_date: cup.end_date&.iso8601,
      swimmer_ids: cup_swimmer_ids,
      no_duplicated_events: no_duplicated_from(cup),
      external_swimmers: external_swimmers_for_ids(external_ids),
      has_ranking_data: cup.ranking_data.present?
    }
  end

  # [POST] Creates or updates the current cup configuration.
  def save # rubocop:disable Metrics/AbcSize
    cup = find_or_initialize_cup
    cup.assign_attributes(
      team_id: @team_id,
      description: params[:description],
      season_year: params[:season_year],
      end_date: params[:end_date],
      swimmers_ids: Array(params[:swimmer_ids]).compact_blank.map(&:to_i).join(',')
    )

    if cup.save
      flash[:notice] = t('goggles_cup.cup_saved')
    else
      flash[:alert] = t('goggles_cup.cup_save_error', errors: cup.errors.full_messages.join(', '))
    end

    redirect_to(goggles_cup_preview_path(team_id: @team_id, goggle_cup_id: cup.id))
  end

  # [GET] Renders the stored ranking HTML for the selected cup as JSON.
  def load_ranking
    cup = GogglesDb::GoggleCup.find_by(id: params[:goggle_cup_id], team_id: @team_id)
    return render json: { error: 'Not found' }, status: :not_found if cup&.ranking_data.blank?

    @goggle_cup = cup
    @ranking_data = GogglesDb::GoggleCupRanking::DataDeserializer.new(cup).call
    instance_vars_from_stored_data(cup)
    render json: { html: ranking_html }
  end

  # [POST] Generates a pushable SQL script for the current cup and stores it in
  # `crawler/data/results.new/goggle_cups/` for later production push.
  def export_sql # rubocop:disable Metrics/AbcSize
    cup = @goggle_cup
    if cup&.ranking_data.blank?
      flash[:alert] = t('goggles_cup.export_sql_error', message: t('goggles_cup.info.no_ranking_data'))
      redirect_to(goggles_cup_preview_path(team_id: @team_id, goggle_cup_id: cup&.id)) && return
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
    redirect_to(goggles_cup_preview_path(team_id: @team_id, goggle_cup_id: cup.id))
  rescue StandardError => e
    flash[:alert] = t('goggles_cup.export_sql_error', message: e.message)
    redirect_to(goggles_cup_preview_path(team_id: @team_id, goggle_cup_id: @goggle_cup&.id))
  end

  # [POST/GET] Computes the GogglesCup ranking for the selected swimmers and renders
  # it in HTML, JSON, CSV, XLSX or PDF formats.
  def compute
    @swimmers_for_team = swimmers_for_team
    @ranking_data = ranking_data
    @goggle_cups = @team ? GogglesDb::GoggleCup.where(team_id: @team.id).order(:season_year, :description) : []
    @external_swimmers = external_swimmers_for(@goggle_cup)

    persist_ranking_data if @goggle_cup && @ranking_data.present? && @selected_swimmer_ids.present?

    respond_to do |format|
      format.html { render(:index) }
      format.json { render json: { html: ranking_html } }
      format.csv { send_ranking_export(format: :csv) }
      format.xlsx { send_ranking_export(format: :xlsx) }
      format.pdf { send_ranking_export(format: :pdf) }
    end
  end

  private

  def set_team
    @team_id = params[:team_id]
    @team = GogglesDb::Team.find_by(id: @team_id) if @team_id.present?
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

  def set_goggle_cup
    goggle_cup_id = params[:goggle_cup_id]
    @goggle_cup = GogglesDb::GoggleCup.find_by(id: goggle_cup_id) if goggle_cup_id.present? && @team.present?
  end

  def swimmers_for_team
    return [] unless @team

    swimmer_options_query.call
  end

  def swimmer_options_query
    @swimmer_options_query ||= GogglesCup::SwimmerOptionsQuery.new(team_id: @team_id)
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

  def external_swimmers_for_ids(external_ids)
    return [] if external_ids.blank?

    GogglesDb::Swimmer.where(id: external_ids)
                      .pluck(:id, :complete_name, :year_of_birth)
                      .map { |r| { swimmer_id: r[0], swimmer_name: r[1], swimmer_year_of_birth: r[2] } }
  end

  def no_duplicated_from(cup)
    return false if cup.ranking_data.blank?

    data = cup.ranking_data.is_a?(String) ? JSON.parse(cup.ranking_data) : cup.ranking_data
    value = data['no_duplicated_events']
    value.nil? ? false : value
  rescue StandardError
    false
  end

  def instance_vars_from_stored_data(cup)
    data = cup.ranking_data.is_a?(String) ? JSON.parse(cup.ranking_data) : cup.ranking_data
    @selected_swimmer_ids = Array(data['swimmer_ids']).map(&:to_s)
    @no_duplicated_events = ActiveModel::Type::Boolean.new.cast(data['no_duplicated_events'])
  rescue StandardError
    @selected_swimmer_ids = []
    @no_duplicated_events = false
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
    redirect_to(goggles_cup_preview_path(team_id: @team_id))
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
