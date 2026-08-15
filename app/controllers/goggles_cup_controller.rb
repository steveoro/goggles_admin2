# frozen_string_literal: true

require 'csv'
require 'axlsx'
require 'prawn'
require 'prawn/table'
Prawn::Fonts::AFM.hide_m17n_warning = true

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
      format.csv { send_csv_data }
      format.xlsx { send_xlsx_data }
      format.pdf { send_pdf_data }
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
      partial: 'goggles_db/goggle_cups/ranking',
      formats: [:html],
      locals: {
        team: @team,
        ranking_data: @ranking_data,
        selected_swimmer_ids: @selected_swimmer_ids,
        secondary_team_id: @secondary_team_id,
        no_duplicated_events: @no_duplicated_events,
        goggle_cup: @goggle_cup,
        show_exports: true
      }
    )
  end

  def send_csv_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_csv_data, filename: "#{export_filename}.csv", type: 'text/csv', disposition: 'attachment')
  end

  def send_xlsx_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_xlsx_package.to_stream.read,
              filename: "#{export_filename}.xlsx",
              type: Mime[:xlsx], disposition: 'attachment')
  end

  def send_pdf_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_pdf_data,
              filename: "#{export_filename}.pdf",
              type: 'application/pdf', disposition: 'attachment')
  end

  def export_filename
    season = @goggle_cup&.season_year || params[:season_year] || Date.current.year
    desc = @goggle_cup&.description || params[:description] || @team.name
    "goggles_cup-#{season}-#{desc.parameterize}"
  end

  def redirect_invalid_export
    flash[:alert] = I18n.t('goggles_cup.errors.invalid_selection_or_data')
    redirect_to(goggles_cup_preview_path(team_id: @team_id))
  end

  def generate_csv_data
    CSV.generate(headers: true) do |csv|
      csv << %w[Rank Swimmer Year_of_Birth Overall_Score Swimmer_ID]
      @ranking_data.each_with_index do |data, index|
        csv << export_row_for(data, index)
      end
    end
  end

  def generate_xlsx_package
    package = Axlsx::Package.new
    workbook = package.workbook
    header_style = workbook.styles.add_style(b: true, sz: 12, bg_color: 'DDDDDD', alignment: { horizontal: :center })
    data_style = workbook.styles.add_style(sz: 11)
    right_style = workbook.styles.add_style(sz: 11, alignment: { horizontal: :right })

    workbook.add_worksheet(name: "GogglesCup-#{@team.name.truncate(20)}") do |sheet|
      sheet.add_row ["GogglesCup #{@team.name}"], style: header_style
      sheet.merge_cells 'A1:E1'
      sheet.add_row
      sheet.add_row %w[Rank Swimmer Year_of_Birth Overall_Score Swimmer_ID], style: header_style
      @ranking_data.each_with_index do |data, index|
        sheet.add_row export_row_for(data, index), style: [right_style, data_style, right_style, right_style, right_style]
      end
      sheet.column_widths 6, 40, 10, 12, 8
    end

    package
  end

  def export_row_for(data, index)
    [index + 1, data[:swimmer_name], data[:swimmer_year_of_birth], format('%.2f', data[:overall_score]), data[:swimmer_id]]
  end

  def generate_pdf_data # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    Prawn::Document.new(page_layout: :portrait, margin: 25) do |pdf|
      pdf.font_size 10
      pdf.text(t('goggles_cup.ranking_for_team', team: @team.name), size: 16, style: :bold, align: :center)
      pdf.move_down 4
      if @goggle_cup
        pdf.text("#{@goggle_cup.season_year} — #{@goggle_cup.description}", size: 12, style: :bold, align: :center)
        pdf.move_down 2
      end
      pdf.text(t('goggles_cup.no_duplicated_events'), size: 8, align: :center)
      pdf.move_up 10
      checkbox_x = (pdf.bounds.width / 2) + (pdf.width_of(t('goggles_cup.no_duplicated_events'), size: 8) / 2) + 4
      checkbox_y = pdf.cursor
      pdf.stroke_rectangle([checkbox_x, checkbox_y], 8, 8)
      if @no_duplicated_events
        pdf.fill_color '000000'
        pdf.text_box('X', at: [checkbox_x + 1.5, checkbox_y - 1], size: 7)
      end
      pdf.move_down 12
      pdf.text("#{t('goggles_cup.computation_details')}, #{t('goggles_cup.formula')}", size: 8, align: :center)
      pdf.move_down 8

      @ranking_data.each_with_index do |data, index|
        pdf.start_new_page if pdf.cursor < 150

        pdf.text("##{index + 1}  #{data[:swimmer_name]}  (#{data[:swimmer_year_of_birth]})",
                 size: 12, style: :bold)
        pdf.move_up 10
        pdf.text("#{t('goggles_cup.overall_score', score: format('%.2f', data[:overall_score]))}  —  ID #{data[:swimmer_id]}",
                 size: 9, color: '000088', style: :bold, align: :right)
        pdf.move_down 4

        table_data = pdf_ranking_table_data(data[:top_rows])
        pdf.table(table_data, header: true, row_colors: %w[F0F0F0 FFFFFF],
                              width: pdf.bounds.width, cell_style: { size: 7, padding: [2, 3] }) do |table|
          table.row(0).font_style = :bold
          table.column(2).align = :right
          table.column(4).align = :right
          table.column(5).align = :right
        end
        pdf.move_down 20
      end
    end.render
  end

  def pdf_ranking_table_data(top_rows) # rubocop:disable Metrics/AbcSize
    header = [
      t('goggles_cup.event_type'),
      t('goggles_cup.meeting_name'),
      t('goggles_cup.total_hundredths'),
      t('goggles_cup.old_meeting_name'),
      t('goggles_cup.old_total_hundredths'),
      t('goggles_cup.row_score')
    ]
    rows = top_rows.map do |top_row|
      row = top_row[:row]
      meeting_info = "#{row.meeting_date}, #{row.meeting_name}\nMeeting ID #{row.meeting_id}, MIR #{row.meeting_individual_result_id}"
      current_timing = "#{row.total_hundredths}\n#{Timing.new.from_hundredths(row.total_hundredths)}"

      if row.old_meeting_date.present?
        old_meeting_info = "#{row.old_meeting_date}, #{row.old_meeting_name}\nMeeting ID #{row.old_meeting_id}, MIR #{row.old_meeting_individual_result_id}"
        old_timing = "#{row.old_total_hundredths}\n#{Timing.new.from_hundredths(row.old_total_hundredths)}"
      else
        old_meeting_info = '-'
        old_timing = '-'
      end

      [
        "#{row.event_type_code} #{row.pool_type_code}m",
        meeting_info,
        current_timing,
        old_meeting_info,
        old_timing,
        format('%.2f', top_row[:row_score])
      ]
    end
    [header] + rows
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
