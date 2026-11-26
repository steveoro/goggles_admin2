# frozen_string_literal: true

module Sources
  #
  # = Sources::ResultsController
  #
  # Results tab (the sources pending in 'results.new/<season>', see Sources::Index::Results) and the "Prepare" of a
  # non-FIN source: SeasonBoard::Scheduler.prepare! (ops lease, queued Ops::PipelineRun) enqueues the phase 10
  # DataFixPrepareJob (origin 'operator', phases 1-5). The job stops at review: committing stays a click on the
  # commit summary. The click is the opt-in: the pipeline planner never queues these sources by itself.
  #
  class ResultsController < BaseController
    # GET /sources/results[?season_id=&focus=]
    def index
      @rows = sources_index.results
      @sql_count = sources_index.sql_count
      @cleanup_count = cleanup_count
    end

    # POST /sources/prepare (path: the source, relative to the data root or absolute; season_id)
    def prepare
      path = file_guard.resolve!(params[:path])
      return redirect_with(:warning, I18n.t('sources.results.prepare.not_a_source')) unless results_source?(path)
      return redirect_with(:warning, I18n.t('sources.results.prepare.fin_source')) if fin_source?(path)

      run = SeasonBoard::Scheduler.prepare!(season_id:, source_path: path.to_s, origin: :operator, up_to: 5)
      if run
        redirect_with(:notice, I18n.t('sources.results.prepare.queued', name: path.basename))
      else
        redirect_with(:warning, I18n.t('sources.results.prepare.refused', name: path.basename))
      end
    end

    private

    # Files the clean-up page would move for the season (0.10.104, the dry run only; nil when it can't be computed).
    def cleanup_count
      Sources::Cleanup::Plan.new(season_id:, data_root:).move_items.size
    rescue StandardError => e
      Rails.logger.warn("[Sources::ResultsController] clean-up count unavailable: #{e.class}: #{e.message}")
      nil
    end

    def redirect_with(level, message)
      flash[level] = message
      redirect_to(sources_results_path(season_id:, focus: params[:path].to_s.split('/').last), status: :see_other)
    end

    # A JSON file of 'results.new/<season>' (the season shown).
    def results_source?(path)
      path.extname == '.json' && path.dirname == file_guard.root.join('results.new', season_id.to_s)
    end

    # True when the source belongs to a FIN calendar row (those are prepared from the Season board). 0.10.103: a FIN
    # source whose FIN id is on no board row of the stored summary (the board's off-board list) may be prepared here.
    def fin_source?(path)
      disk = SeasonBoard::DiskIndex.new(season_id:, data_dir: data_root)
      base = Ops::PipelineSource.base_for(path.to_s)
      fin_event_id = disk.fin_event_id_for_base(base)
      fin_event_id.present? && !off_board?(fin_event_id)
    end

    # True when the stored board summary of the season has no row with the FIN id (unknown: false).
    def off_board?(fin_event_id)
      board_ids = SeasonBoard::Snapshot.board_fin_event_ids(season_id)
      board_ids ? board_ids.exclude?(fin_event_id.to_s) : false
    end
  end
end
