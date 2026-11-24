# frozen_string_literal: true

module Sources
  #
  # = Sources::ManifestsController
  #
  # Manifests tab (the manifest PDFs waiting in 'manifests/<season>') and their extraction, which has one path:
  # ManifestExtractJob ('background' worker) running PdfManifests::Extraction, per file or for the next
  # BATCH_SIZE pending files (priority 10, so the board crawls go first). A PDF whose base belongs to a FIN calendar
  # row is queued through SeasonBoard::Scheduler.extract! (tracked on its board row).
  #
  class ManifestsController < BaseController
    # "Extract next N"
    BATCH_SIZE = 20

    # GET /sources/manifests[?season_id=&focus=]
    def index
      @engine = params.fetch(:engine, nil).presence_in(PdfManifests::ClientFactory::ENGINES) || PdfManifests::ClientFactory.default_engine
      @rows = sources_index.manifests(engine: @engine)
      @done_count = sources_index.done_manifest_count
    end

    # POST /sources/manifests/extract (pdf_path: one file, or batch=1: the next BATCH_SIZE files; engine)
    def extract
      engine = params.fetch(:engine, nil).presence_in(PdfManifests::ClientFactory::ENGINES)
      return extract_batch(engine) if params[:batch].present?

      pdf_path = manifest_path!(params[:pdf_path])
      queued = Sources::ManifestQueue.new(season_id:, data_root: file_guard.root).enqueue(pdf_path, engine:)
      flash[queued ? :notice : :warning] = I18n.t(queued ? 'sources.manifests.extract.queued' : 'sources.manifests.extract.busy',
                                                  name: pdf_path.basename)
      redirect_to(sources_manifests_path(season_id:, engine:), status: :see_other)
    end

    private

    def extract_batch(engine)
      preflight = PdfManifests::Extraction.preflight_error(engine:)
      if preflight
        flash[:warning] = PdfManifests::Extraction.preflight_message(preflight, engine:)
      else
        count = Sources::ManifestQueue.new(season_id:, data_root: file_guard.root).enqueue_next(BATCH_SIZE, engine:)
        flash[count.positive? ? :notice : :warning] = I18n.t('sources.manifests.extract.batch_queued', count:)
      end
      redirect_to(sources_manifests_path(season_id:, engine:), status: :see_other)
    end

    # Real path of a PDF in 'manifests/<season>' (raises Refused otherwise).
    def manifest_path!(value)
      path = file_guard.resolve!(value)
      valid = path.extname.casecmp?('.pdf') && path.dirname == file_guard.root.join('manifests', season_id.to_s)
      raise Sources::FileGuard::Refused.new(:outside, value) unless valid

      path
    end
  end
end
