# frozen_string_literal: true

require 'csv'
require 'axlsx'
require 'prawn'
require 'prawn/table'
Prawn::Fonts::AFM.hide_m17n_warning = true

# = GogglesCupController
class GogglesCupController < ApplicationController
  before_action :authenticate_user!
  before_action :set_team, only: %i[index smart_selection compute]
  before_action :set_secondary_team, only: %i[index compute]
  before_action :set_selected_swimmer_ids, only: %i[compute]
  before_action :set_no_duplicated_events, only: %i[compute]

  def index
    @swimmers_for_team = swimmers_for_team
    @ranking_data = []
  end

  def smart_selection
    selected_ids = @team ? swimmer_options_query.smart_selected_ids_for(params[:secondary_team_id]) : []

    render json: { swimmer_ids: selected_ids }
  end

  def compute
    @swimmers_for_team = swimmers_for_team
    @ranking_data = ranking_data

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

  def swimmers_for_team
    return [] unless @team

    swimmer_options_query.call
  end

  def swimmer_options_query
    @swimmer_options_query ||= GogglesCup::SwimmerOptionsQuery.new(team_id: @team_id)
  end

  def ranking_data
    return [] unless @team && @selected_swimmer_ids.present?

    GogglesCup::RankingCalculator.new(
      team_id: @team_id,
      swimmer_ids: @selected_swimmer_ids,
      no_duplicated_events: @no_duplicated_events
    ).call
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
        no_duplicated_events: @no_duplicated_events
      }
    )
  end

  def send_csv_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_csv_data, filename: "goggles_cup_#{@team.name.parameterize}.csv", type: 'text/csv', disposition: 'attachment')
  end

  def send_xlsx_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_xlsx_package.to_stream.read,
              filename: "goggles_cup_#{@team.name.parameterize}.xlsx",
              type: Mime[:xlsx], disposition: 'attachment')
  end

  def send_pdf_data
    return redirect_invalid_export unless @team && @ranking_data.present?

    send_data(generate_pdf_data,
              filename: "goggles_cup_#{@team.name.parameterize}.pdf",
              type: 'application/pdf', disposition: 'attachment')
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

  def generate_pdf_data # rubocop:disable Metrics/AbcSize
    Prawn::Document.new(page_layout: :portrait, margin: 25) do |pdf|
      pdf.font_size 10
      pdf.text(t('goggles_cup.ranking_for_team', team: @team.name), size: 16, style: :bold, align: :center)
      pdf.move_down 4
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
end
