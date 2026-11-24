# frozen_string_literal: true

module PdfManifests
  #
  # = PdfManifests::Extraction
  #
  # The one manifest-extraction path (phase 15), used by ManifestExtractJob (Season board, Sources, the pipeline
  # planner) and by 'rake manifests:extract': the engine preflight, the Extractor run on a single PDF and the archival
  # of a processed manifest (the PDF and its '.txt' sibling move to 'manifests.done/<season>').
  #
  # == Usage
  #   result = PdfManifests::Extraction.call(pdf_path: '.../manifests/262/manifest-x.pdf', engine: 'devin')
  #   result.status   # => :done | :failed
  #   result.message  # => 'extracted (12 events)' | 'skipped: output already exists' | 'LLM engine unavailable' | ...
  #   result.archived? / result.extractor_result (PdfManifests::Extractor::Result, nil after a failed preflight)
  #
  # Never raises for an engine or a data problem (the result says it); unexpected errors propagate to the caller.
  #
  class Extraction
    # Short (job and activity log) messages of the preflight blockers.
    PREFLIGHT_MESSAGES = {
      engine_unavailable: 'LLM engine unavailable',
      model_missing: 'LLM model missing'
    }.freeze

    Result = Data.define(:status, :message, :extractor_result, :preflight, :archived) do
      def done? = status == :done
      def archived? = archived
    end

    # Runs the extraction of one PDF (see the class notes).
    # - engine / model: LLM engine and model (nil: the defaults, see ClientFactory); client: an already built client
    #   (rake reuses one for every file);
    # - force: regenerate an existing manifest output; data_root: the 'crawler/data' folder (outputs in its
    #   'results.new/<season>');
    # - preflight: false when the caller already checked the engine (rake checks it once for every file).
    def self.call(pdf_path:, engine: nil, model: nil, force: false, data_root: Rails.root.join('crawler/data'), client: nil, preflight: true) # rubocop:disable Metrics/ParameterLists
      new(pdf_path:, engine:, model:, force:, data_root:, client:).call(preflight:)
    end

    # Nil when the engine can run, else :engine_unavailable | :model_missing.
    def self.preflight_error(engine: nil, model: nil, client: nil)
      client ||= ClientFactory.build(engine:, model:)
      return :engine_unavailable unless client.available?
      return :model_missing unless client.model_available?

      nil
    end

    # Operator message (flash) of a preflight blocker, with the engine hint.
    def self.preflight_message(error, engine: nil, model: nil)
      client = ClientFactory.build(engine:, model:)
      case error
      when :engine_unavailable
        I18n.t('sources.manifests.extract.engine_unavailable', engine: client.engine_name, hint: client.unavailable_hint)
      else
        I18n.t('sources.manifests.extract.model_missing', model: client.model, engine: client.engine_name, hint: client.model_missing_hint)
      end
    end

    # Moves a processed manifest PDF and its '.txt' sibling into the 'manifests.done' counterpart folder, keeping the
    # season subfolder. No-op for a file stored outside a 'manifests/' folder. Returns true when something moved.
    def self.archive(pdf_path) # rubocop:disable Naming/PredicateMethod
      src_dir = File.dirname(pdf_path.to_s)
      done_dir = src_dir.sub(%r{/manifests(/|\z)}, '/manifests.done\1')
      return false if done_dir == src_dir

      FileUtils.mkdir_p(done_dir)
      moved = [pdf_path.to_s, pdf_path.to_s.sub(/\.pdf\z/i, '.txt')].select { |src_path| File.exist?(src_path) }
      moved.each { |src_path| FileUtils.mv(src_path, File.join(done_dir, File.basename(src_path))) }
      moved.any?
    end

    def initialize(pdf_path:, engine: nil, model: nil, force: false, data_root: Rails.root.join('crawler/data'), client: nil) # rubocop:disable Metrics/ParameterLists
      @pdf_path = pdf_path.to_s
      @force = force
      @data_root = Pathname.new(data_root)
      @client = client || ClientFactory.build(engine:, model:)
    end

    def call(preflight: true)
      error = preflight ? self.class.preflight_error(client: @client) : nil
      return result(:failed, PREFLIGHT_MESSAGES.fetch(error), preflight: error) if error

      extracted = Extractor.new(client: @client, results_root: @data_root.join('results.new')).call(@pdf_path, force: @force)
      return result(:failed, "extraction failed: #{extracted.skipped_reason}".truncate(200), extracted:) unless extracted.archivable?

      archived = self.class.archive(@pdf_path)
      message = extracted.success? ? "extracted (#{extracted.events_count.to_i} events)" : "skipped: #{extracted.skipped_reason}".truncate(200)
      result(:done, message, extracted:, archived:)
    end

    private

    def result(status, message, extracted: nil, preflight: nil, archived: false)
      Result.new(status:, message:, extractor_result: extracted, preflight:, archived:)
    end
  end
end
