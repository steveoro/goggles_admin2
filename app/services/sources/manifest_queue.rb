# frozen_string_literal: true

module Sources
  #
  # = Sources::ManifestQueue
  #
  # Queues the manifest extractions of the Sources Manifests tab (one ManifestExtractJob per PDF, the one extraction
  # path of phase 15):
  # - #enqueue: one PDF. When its base belongs to a FIN calendar row (SeasonBoard::DiskIndex) the request goes through
  #   SeasonBoard::Scheduler.extract! (logged under the FIN event id, like the board button and the automatic
  #   extractions, so neither of them queues the same PDF again); otherwise the job gets the PDF path and the activity
  #   is logged under the PDF source key ('src:<sha1>', label: the file name). A PDF already queued or running under
  #   either key is skipped;
  # - #enqueue_next: the next +count+ pending PDFs (oldest name first, each one inside 'manifests/<season>' of the data
  #   root: Sources::FileGuard) not already queued or running, at priority BATCH_PRIORITY.
  #
  class ManifestQueue
    # Priority of the "next 20" batch (the board crawls, priority 0, go first on the serial 'background' worker).
    BATCH_PRIORITY = 10

    def initialize(season_id:, data_root: Sources.data_root)
      @season_id = season_id.to_i
      @data_root = Pathname.new(data_root)
    end

    # Queues one PDF (an absolute real path inside 'manifests/<season>'); returns false when it is already busy.
    def enqueue(pdf_path, engine: nil, priority: nil)
      key = SeasonBoard::ActivityLog.source_key('extract', pdf_path.to_s)
      return false if log.busy?(key, kind: :extract)

      fin_event_id = disk_index.fin_event_id_for_base(File.basename(pdf_path.to_s, '.*').delete_prefix('manifest-'))
      return SeasonBoard::Scheduler.extract!(season_id: @season_id, fin_event_id:, engine:, pdf_path: pdf_path.to_s, priority:) if fin_event_id

      log.queue!(key, kind: :extract, origin: :manual, label: File.basename(pdf_path.to_s))
      (priority ? ManifestExtractJob.set(priority:) : ManifestExtractJob).perform_later(season_id: @season_id, pdf_path: pdf_path.to_s, engine:)
      SeasonBoard::Notifier.ping
      true
    end

    # Queues the next +count+ pending PDFs; returns how many were queued.
    def enqueue_next(count, engine: nil)
      pending_paths.lazy.select { |path| enqueue(path, engine:, priority: BATCH_PRIORITY) }.first(count).size
    end

    private

    # Real paths (Strings, sorted) of the PDFs of 'manifests/<season>' that resolve inside that folder.
    def pending_paths
      guard = FileGuard.new(root: @data_root)
      folder = guard.root.join('manifests', @season_id.to_s)
      @data_root.join('manifests', @season_id.to_s).glob('*.pdf').sort.filter_map do |path|
        real = guard.resolve!(path)
        real.to_s if real.dirname == folder
      rescue FileGuard::Refused
        nil
      end
    end

    def log
      @log ||= SeasonBoard::ActivityLog.new
    end

    def disk_index
      @disk_index ||= SeasonBoard::DiskIndex.new(season_id: @season_id, data_dir: @data_root)
    end
  end
end
