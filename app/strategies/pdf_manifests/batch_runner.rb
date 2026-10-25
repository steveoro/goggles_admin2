# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::BatchRunner
  #
  #   - version:  7-0.10.63
  #   - author:   Devin
  #
  # Runs the manifest-extraction pipeline over every PDF found under
  # 'crawler/data/manifests/<season_id>/' — the same job performed by the
  # 'manifests:extract' rake task — and reports progress on a JSON status file
  # (gitignored, inside crawler/data) so a UI caller can poll it.
  #
  # Extracted artifacts land in 'crawler/data/results.new/<season_id>/' as
  # layoutType-4 sources; processed manifests (.pdf + .txt siblings) are moved
  # to 'manifests.done/<season>/' by ::archive.
  #
  # Designed to run inside a background Thread (localhost admin tool): the
  # process-local active flag plus the status file 'updated_at' heartbeat keep
  # the UI from thinking a killed run is still going.
  #
  # == Usage:
  #   runner = PdfManifests::BatchRunner.new(season_id: 262)
  #   if runner.preflight_error.nil? && !PdfManifests::BatchRunner.running?
  #     Thread.new { runner.call }
  #   end
  #
  class BatchRunner
    # Status file lives under crawler/data (already gitignored).
    STATUS_FILENAME = 'manifests-extract-status.json'

    # A status file older than this is considered stale (dead run).
    RUNNING_STALE_AFTER = 600 # seconds

    attr_reader :season_id, :model, :data_root, :client, :pdf_list

    def initialize(season_id:, model: nil, force: false, data_root: Rails.root.join('crawler/data'))
      @season_id = season_id
      @model = model
      @force = force
      @data_root = Pathname(data_root)
      @client = OllamaClient.new(model: model)
      @pdf_list = @data_root.glob("manifests/#{season_id}/*.pdf").sort
    end

    # Nil when the batch can start; otherwise a Symbol describing the blocker:
    #   :ollama_unavailable | :model_missing | :no_manifests
    def preflight_error
      return :ollama_unavailable unless client.available?
      return :model_missing unless client.model_available?
      return :no_manifests if pdf_list.empty?

      nil
    end

    # Marks the batch as active synchronously (so a following page render
    # already sees running?=true), then starts #call in a daemon Thread.
    def start_in_thread!
      self.class.mark_active!
      Thread.new { call }
    rescue StandardError
      self.class.mark_inactive!
      raise
    end

    # Executes the batch, updating the status file after each PDF.
    # Individual failures do not abort the run; they are collected in the
    # status 'errors' list and counted under 'failed'.
    def call
      return unless preflight_error.nil?

      stats = { extracted: 0, skipped: 0, failed: 0 }
      errors = []
      self.class.mark_active!
      write_status(running: true, status: 'OK, extracting', detail: 'starting', progress: 0)
      extractor = Extractor.new(client: client)

      pdf_list.each_with_index do |pdf_path, idx|
        process_one(extractor, pdf_path, idx, stats, errors)
      end

      write_status(running: false, status: 'OK, done', detail: 'extraction finished',
                   progress: pdf_list.size,
                   extracted: stats[:extracted], skipped: stats[:skipped],
                   failed: stats[:failed], errors: errors, finished: true)
      stats
    rescue StandardError => e
      write_status(running: false, status: 'ERROR', detail: e.message, errors: errors || [])
      raise
    ensure
      self.class.mark_inactive!
    end

    # -----------------------------------------------------------------
    # Class-level state & helpers
    # -----------------------------------------------------------------

    @active = false
    @active_mutex = Mutex.new

    class << self
      # Marks a batch run as active/finished (process-local guard).
      def mark_active!
        @active_mutex.synchronize { @active = true }
      end

      def mark_inactive!
        @active_mutex.synchronize { @active = false }
      end

      # TRUE while a batch is running in this process, or the status file shows
      # a recent (non-stale) running flag (e.g. a parallel `rake manifests:extract`
      # run reporting through the same file).
      def running?(data_root: Rails.root.join('crawler/data'))
        return true if @active_mutex.synchronize { @active }

        status = read_status(data_root: data_root)
        return false unless status['running']

        updated_at = status['updated_at'].to_s
        updated_at.present? && Time.iso8601(updated_at) > RUNNING_STALE_AFTER.seconds.ago
      rescue StandardError
        @active_mutex.synchronize { @active }
      end

      # Last persisted status Hash ({} when missing/corrupt).
      def read_status(data_root: Rails.root.join('crawler/data'))
        path = Pathname(data_root).join(STATUS_FILENAME)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path)) || {}
      rescue JSON::ParserError
        {}
      end

      # Moves a processed manifest PDF and its '.txt' sibling into the
      # 'manifests.done' counterpart dir, keeping the season sub-folder.
      # No-op for source files stored outside a 'manifests/' directory.
      def archive(pdf_path)
        src_dir = File.dirname(pdf_path.to_s)
        done_dir = src_dir.sub(%r{/manifests(/|\z)}, '/manifests.done\1')
        return if done_dir == src_dir

        FileUtils.mkdir_p(done_dir)
        [pdf_path.to_s, pdf_path.to_s.sub(/\.pdf\z/i, '.txt')].each do |src_path|
          FileUtils.mv(src_path, File.join(done_dir, File.basename(src_path))) if File.exist?(src_path)
        end
      end
    end

    private

    # Extracts a single PDF, updating stats/errors in place and persisting the
    # 'currently processing' status beforehand. Failures never raise.
    def process_one(extractor, pdf_path, idx, stats, errors)
      base = File.basename(pdf_path)
      write_status(running: true, status: 'OK, extracting', detail: base,
                   progress: idx, extracted: stats[:extracted], skipped: stats[:skipped],
                   failed: stats[:failed], errors: errors)

      result = extractor.call(pdf_path, force: @force)
      if result.success? || result.skipped_reason.to_s.start_with?('output already exists')
        stats[result.success? ? :extracted : :skipped] += 1
        self.class.archive(pdf_path)
      else
        stats[:failed] += 1
        errors << "#{base}: #{result.skipped_reason}"
      end
    rescue StandardError => e
      stats[:failed] += 1
      errors << "#{base}: #{e.message}"
    end

    def status_path
      data_root.join(STATUS_FILENAME)
    end

    def write_status(payload)
      now = Time.now.utc.iso8601
      @started_at ||= now
      status = payload.merge(
        timestamp: now,
        season_id: season_id,
        model: client.model,
        total: pdf_list.size,
        updated_at: now,
        started_at: @started_at
      )
      status[:finished_at] = now if status.delete(:finished)
      File.write(status_path, JSON.pretty_generate(status.stringify_keys))
    rescue StandardError => e
      Rails.logger.warn("[PdfManifests::BatchRunner] status write failed: #{e.message}")
    end
  end
end
