# frozen_string_literal: true

# = SeasonBoardController
#
# One-page weekly flow for the latest MASFIN season: one row per FIN calendar row, with the linked
# local meeting, the pipeline state and a single next action (see SeasonBoard::Builder).
#
# The actions that start work (+crawl+, +extract+, +link+) take only the FIN event ID: the URLs are
# always looked up from the current board rows (the stored board summary, see SeasonBoard::Snapshot,
# fresh by fingerprint), never from the request params. These POST actions run no board build of
# their own while the stored summary is fresh.
#
# +link+ writes the local DB and an Outbox script: it passes the DB sync gate first (Drift::Gate, scope
# :board_write: red and amber warn, nothing blocks). A warning not ticked yet renders a confirmation page whose
# form posts the same link again with <tt>drift_ack=1</tt>.
#
# Pipeline automation (phase 10): +prepare+ queues a DataFixPrepareJob for the row's source (the "Prepare" and
# "Retry" buttons; phases 1-5 only, never a commit), +hold+ toggles the row hold (no automatic prepare), and
# +prepare_all+ runs the pipeline planner now (PipelinePlannerJob). Nothing here commits or pushes.
#
class SeasonBoardController < ApplicationController # rubocop:disable Metrics/ClassLength
  # Extraction engines offered by the existing manifest extraction form (see pull/calendar_meetings):
  ENGINES = %w[devin ollama].freeze

  before_action :set_season, except: :index
  helper_method :rows_frame_locals

  # [GET] The board, always built live (the build is stored as the board summary).
  # Filters (all optional, kept in the query string):
  # - state: shows only the rows in that state;
  # - show_unlinked: includes the rows w/o a FIN link (state not_linked);
  # - show_done: includes the past rows already committed with results.
  # With <tt>frame=1</tt> only the rows frame ('season-board-rows') is rendered, without the layout
  # (used by the live refresh, see season_board_controller.js).
  def index
    season = SeasonBoard::Builder.latest_season
    if season.nil?
      flash[:warning] = I18n.t('season_board.flash.no_season')
      redirect_to(root_path) && return
    end

    @season = season
    @board = SeasonBoard::Snapshot.build!(season)
    assign_counts
    assign_filters
    @rows = visible_rows
    render_rows_frame if params[:frame].present?
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

  # [POST] Queues a Data-Fix prepare (DataFixPrepareJob, origin operator) of the row's source: "Prepare" / "Retry".
  def prepare
    row = find_row
    redirect_to(season_board_path) && return unless row

    source_path = row_source_path(row)
    if source_path.blank?
      flash[:warning] = I18n.t('pipeline_automation.flash.no_source', fin_event_id: row.fin_event_id)
    else
      enqueue(row, :prepare_queued, busy_key: :prepare_busy) do
        SeasonBoard::Scheduler.prepare!(season_id: @season.id, source_path:, origin: :operator, fin_event_id: row.fin_event_id).present?
      end
    end
    redirect_to(season_board_path(anchor: SeasonBoard::ActionPaths.row_dom_id(row.fin_event_id)))
  end

  # [POST] Holds (hold=1) or releases (hold=0) the row's source: a held source is never prepared automatically.
  def hold
    row = find_row
    redirect_to(season_board_path) && return unless row

    flash_hold_result(row, params[:hold].to_s == '1')
    redirect_to(season_board_path(anchor: SeasonBoard::ActionPaths.row_dom_id(row.fin_event_id)))
  end

  # [POST] "Prepare all": runs the pipeline planner now (same rules and switches as the 15-minute pass).
  def prepare_all
    if DataFix::Automation.enabled?(:auto_prepare)
      PipelinePlannerJob.perform_later(trigger: 'board')
      flash[:info] = I18n.t('pipeline_automation.flash.planner_queued')
    else
      flash[:warning] = I18n.t('pipeline_automation.flash.paused')
    end
  rescue StandardError => e
    Rails.logger.error("[SeasonBoardController] planner not queued: #{e.class}: #{e.message}")
    flash[:error] = I18n.t('pipeline_automation.flash.planner_failed', error: e.message)
  ensure
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
    return if refused_by_drift_gate?(row, calendar_id)

    result = SeasonBoard::CalendarLinker.new(season: @season, calendar_id:, fin_event_id: row.fin_event_id,
                                             results_link: row.url).call
    flash_link_result(result, row, calendar_id)
    redirect_to(season_board_path)
  end

  private

  # DB sync gate of the board writes (scope :board_write). Returns true after rendering the confirmation page
  # (a warning not ticked yet) or redirecting (a blocking verdict: never for this scope, kept for safety).
  def refused_by_drift_gate?(row, calendar_id)
    @gate = Drift::Gate.check(scope: :board_write, acknowledged: params[:drift_ack].to_s == '1')
    return false if @gate.allowed?

    if @gate.block?
      flash[:error] = I18n.t('db_sync.gate.blocked', summary: @gate.summary)
      redirect_to(db_sync_path)
    else
      @row = row
      @calendar_id = calendar_id
      render(:confirm_link, status: :unprocessable_content)
    end
    true
  end

  # Renders only the rows frame partial, without the layout (live refresh).
  def render_rows_frame
    render(partial: 'season_board/rows_frame', locals: rows_frame_locals, layout: false)
  end

  # Locals of the 'season_board/rows_frame' partial.
  def rows_frame_locals
    {
      board: @board, rows: @rows, state_counts: @state_counts, unlinked_count: @unlinked_count, done_count: @done_count,
      state_filter: @state_filter, show_unlinked: @show_unlinked, show_done: @show_done
    }
  end

  # Loads the current season (never from params)
  def set_season
    @season = SeasonBoard::Builder.latest_season
  end

  # Returns the current board row (a SeasonBoard::Snapshot::Row, from the stored board summary when
  # fresh, else from a new build) for the FIN event ID param and having a FIN URL, or nil after
  # setting the refusal flash.
  def find_row
    fin_event_id = params[:fin_event_id].to_s.strip
    if @season.nil?
      flash[:warning] = I18n.t('season_board.flash.no_season')
      return
    end

    row = SeasonBoard::Snapshot.fetch(@season).rows.find do |r|
      r.fin_event_id.present? && r.fin_event_id == fin_event_id && r.url.present?
    end
    flash[:error] = I18n.t('season_board.flash.unknown_row', fin_event_id:) unless row
    row
  end

  # Runs the Scheduler call in the block, setting the flash for its outcome (block result true: queued,
  # false: busy). The Scheduler re-raises when the enqueue itself fails (e.g. missing queue database):
  # the error is shown in the flash instead of a 500.
  # (+queued_key+ / +busy_key+: under season_board.flash, or pipeline_automation.flash for the prepare)
  def enqueue(row, queued_key, busy_key: :busy)
    fin_event_id = row.fin_event_id
    scope = queued_key == :prepare_queued ? 'pipeline_automation.flash' : 'season_board.flash'
    if yield
      flash[:info] = I18n.t("#{scope}.#{queued_key}", fin_event_id:)
    else
      flash[:warning] = I18n.t("#{busy_key == :busy ? 'season_board.flash' : scope}.#{busy_key}", fin_event_id:)
    end
  rescue StandardError => e
    Rails.logger.error("[SeasonBoardController] enqueue failed for FIN #{fin_event_id}: #{e.class}: #{e.message}")
    flash[:error] = I18n.t('season_board.flash.enqueue_failed', fin_event_id:, error: e.message)
  end

  # Source of the row (the file the review / commit actions of its next action point to), or nil.
  def row_source_path(row)
    row.next_action&.params&.dig(:file_path).presence
  end

  def flash_hold_result(row, held)
    source_path = row_source_path(row)
    fin_event_id = row.fin_event_id
    if source_path.blank? || !Ops.available?
      flash[:warning] = I18n.t('pipeline_automation.flash.no_source', fin_event_id:)
    elsif store_hold(source_path, held, row)
      flash[:info] = I18n.t("pipeline_automation.flash.#{held ? 'held' : 'released'}", fin_event_id:)
    else
      flash[:error] = I18n.t('pipeline_automation.flash.hold_failed', fin_event_id:)
    end
  end

  # Stores the row hold on the Ops::PipelineSource of the source (+ an 'automation.row_held' / '_released' event).
  def store_hold(source_path, held, row)
    Ops.safely(false) do
      season_id = Ops::PipelineSource.season_id_for(source_path)
      source = Ops::PipelineSource.for_path!(source_path, season_id: season_id.positive? ? season_id : @season.id)
      source.update!(auto_prepare: !held)
      Ops.record_event!(kind: "automation.row_#{held ? 'held' : 'released'}", level: 'info', actor: 'operator', season_id: @season.id,
                        subject_type: 'fin_event', subject_key: row.fin_event_id,
                        data: { 'base' => source.base, 'user_id' => current_user&.id }, link_path: season_board_path)
      SeasonBoard::Snapshot.invalidate!(@season.id)
      true
    end
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

  def assign_filters
    @state_filter = params[:state].to_s.presence_in(SeasonBoard::Builder::STATES.map(&:to_s))
    @show_unlinked = params[:show_unlinked].present?
    @show_done = params[:show_done].present?
  end

  def assign_counts
    @state_counts = @board.state_counts
    @unlinked_count = @board.unlinked_count
    @done_count = @board.done_count
  end

  # Past rows already committed with results: hidden by default
  def hidden_as_done?(row)
    SeasonBoard::Builder.hidden_as_done?(row)
  end

  def visible_rows
    return @board.rows.select { |row| row.state.to_s == @state_filter } if @state_filter

    @board.rows.reject do |row|
      (row.state == :not_linked && !@show_unlinked) || (hidden_as_done?(row) && !@show_done)
    end
  end
end
