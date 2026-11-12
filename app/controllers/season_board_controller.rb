# frozen_string_literal: true

# = SeasonBoardController
#
# One-page weekly flow for the latest MASFIN season: one row per FIN calendar row, with the linked
# local meeting, the pipeline state and a single next action (see SeasonBoard::Builder).
#
# The actions that start work (+crawl+, +extract+, +link+) take only the FIN event ID: the URLs are
# always looked up from the current board rows, never from the request params.
#
class SeasonBoardController < ApplicationController
  # Extraction engines offered by the existing manifest extraction form (see pull/calendar_meetings):
  ENGINES = %w[devin ollama].freeze

  before_action :set_board, except: :index

  # [GET] The board. Filters (all optional, kept in the query string):
  # - state: shows only the rows in that state;
  # - show_unlinked: includes the rows w/o a FIN link (state not_linked);
  # - show_done: includes the past rows already committed with results.
  def index
    season = SeasonBoard::Builder.latest_season
    if season.nil?
      flash[:warning] = I18n.t('season_board.flash.no_season')
      redirect_to(root_path) && return
    end

    @season = season
    @board = SeasonBoard::Builder.new(season:).call
    assign_counts
    @state_filter = params[:state].to_s.presence_in(SeasonBoard::Builder::STATES.map(&:to_s))
    @show_unlinked = params[:show_unlinked].present?
    @show_done = params[:show_done].present?
    @rows = visible_rows
  end

  # [POST] Queues a crawl of the FIN results page of the row (used by :crawl & :check_results).
  def crawl
    row = find_row
    redirect_to(season_board_path) && return unless row

    enqueue(row, :crawl_queued) do
      SeasonBoard::Scheduler.crawl!(season_id: @season.id, fin_event_id: row.fin_event_id, url: row.url, origin: :manual)
    end
    redirect_to(season_board_path)
  end

  # [POST] Queues the manifest extraction for the row. Optional <tt>engine</tt> (devin|ollama).
  def extract
    row = find_row
    redirect_to(season_board_path) && return unless row

    engine = params[:engine].presence
    if engine && ENGINES.exclude?(engine)
      flash[:error] = I18n.t('season_board.flash.invalid_engine', engine:)
    else
      enqueue(row, :extract_queued) { SeasonBoard::Scheduler.extract!(season_id: @season.id, fin_event_id: row.fin_event_id, engine:) }
    end
    redirect_to(season_board_path)
  end

  # [POST] Links the FIN event of the row to an existing (orphan) calendar row.
  def link
    row = find_row
    redirect_to(season_board_path) && return unless row

    calendar_id = params[:calendar_id].to_i
    if calendar_id.zero?
      flash[:warning] = I18n.t('season_board.flash.link_missing_params')
      redirect_to(season_board_path) && return
    end

    result = SeasonBoard::CalendarLinker.new(season: @season, calendar_id:, fin_event_id: row.fin_event_id,
                                             results_link: row.url).call
    flash_link_result(result, row, calendar_id)
    redirect_to(season_board_path)
  end

  private

  # Loads the current season & board rows (never from params)
  def set_board
    @season = SeasonBoard::Builder.latest_season
    @board = SeasonBoard::Builder.new(season: @season).call if @season
  end

  # Returns the current board row for the FIN event ID param (and having a FIN URL), or nil
  # after setting the refusal flash.
  def find_row
    fin_event_id = params[:fin_event_id].to_s.strip
    if @board.nil?
      flash[:warning] = I18n.t('season_board.flash.no_season')
      return
    end

    row = @board&.rows&.find { |r| r.fin_event_id.present? && r.fin_event_id == fin_event_id && r.url.present? }
    flash[:error] = I18n.t('season_board.flash.unknown_row', fin_event_id:) unless row
    row
  end

  # Runs the Scheduler call in the block, setting the flash for its outcome (block result true: queued,
  # false: busy). The Scheduler re-raises when the enqueue itself fails (e.g. missing queue database):
  # the error is shown in the flash instead of a 500.
  def enqueue(row, queued_key)
    fin_event_id = row.fin_event_id
    if yield
      flash[:info] = I18n.t("season_board.flash.#{queued_key}", fin_event_id:)
    else
      flash[:warning] = I18n.t('season_board.flash.busy', fin_event_id:)
    end
  rescue StandardError => e
    Rails.logger.error("[SeasonBoardController] enqueue failed for FIN #{fin_event_id}: #{e.class}: #{e.message}")
    flash[:error] = I18n.t('season_board.flash.enqueue_failed', fin_event_id:, error: e.message)
  end

  def flash_link_result(result, row, calendar_id)
    if !result.success?
      flash[:error] = I18n.t('season_board.flash.link_failed', error: result.error)
    elsif result.sql_path.present?
      flash[:notice] = I18n.t('season_board.flash.linked', fin_event_id: row.fin_event_id, calendar_id:,
                                                           file: File.basename(result.sql_path))
    else
      flash[:info] = I18n.t('season_board.flash.linked_no_changes', fin_event_id: row.fin_event_id, calendar_id:)
    end
  end

  def assign_counts
    @state_counts = @board.rows.map(&:state).tally
    @unlinked_count = @state_counts.fetch(:not_linked, 0)
    @done_count = @board.rows.count { |row| hidden_as_done?(row) }
  end

  # Past rows already committed with results: hidden by default
  def hidden_as_done?(row)
    row.state == :committed_with_results && (row.last_date.nil? || row.last_date < Date.current)
  end

  def visible_rows
    return @board.rows.select { |row| row.state.to_s == @state_filter } if @state_filter

    @board.rows.reject do |row|
      (row.state == :not_linked && !@show_unlinked) || (hidden_as_done?(row) && !@show_done)
    end
  end
end
