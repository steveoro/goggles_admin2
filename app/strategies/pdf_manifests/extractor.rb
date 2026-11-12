# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::Extractor
  #
  #   - version:  7-0.10.66
  #   - author:   Devin
  #
  # Orchestrates the extraction of meeting data from a manifest PDF:
  #
  #   PDF ──pdftotext──► text ──Ollama LLM──► extracted Hash
  #     │                                    │
  #     └─ (scanned: pdftoppm ─► images) ────┘
  #                                          ▼
  #   Lt4Builder ──► LT4 Hash ──► results.new/<season>/<base>-lt4.json
  #
  # == Usage:
  #   result = PdfManifests::Extractor.new.call(pdf_path)
  #   result.out_path # => ".../results.new/262/2026-10-25-...-lt4.json" (or nil)
  #
  class Extractor # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end

    # Skip reasons that still mark the manifest as processed (callers archive
    # the PDF): an earlier extraction is already in place, or the output path
    # already holds a results source that a manifest must never overwrite.
    SKIP_OUTPUT_EXISTS = 'output already exists'
    SKIP_RESULTS_PRESENT = 'results source already present'
    ARCHIVABLE_SKIPS = [SKIP_OUTPUT_EXISTS, SKIP_RESULTS_PRESENT].freeze

    # Returned per processed file.
    Result = Struct.new(:pdf_path, :out_path, :warnings, :events_count, :skipped_reason, keyword_init: true) do
      def success?
        out_path.present?
      end

      # TRUE for a skip that needs no retry (see ARCHIVABLE_SKIPS).
      def archivable_skip?
        !success? && ARCHIVABLE_SKIPS.any? { |prefix| skipped_reason.to_s.start_with?(prefix) }
      end

      # TRUE when the processed manifest can be moved to 'manifests.done'.
      def archivable?
        success? || archivable_skip?
      end
    end

    # == Params
    # - client: LLM client (see ClientFactory)
    # - results_root: base 'results.new' folder; outputs land in '<results_root>/<season_id>/'
    def initialize(client: ClientFactory.build, results_root: Rails.root.join('crawler/data/results.new'))
      @client = client
      @results_root = results_root.to_s
    end

    # Processes a single manifest PDF and writes the LT4 source file under
    # 'crawler/data/results.new/<season_id>/'.
    #
    # Never raises for data-level problems: failures are returned inside
    # Result#skipped_reason so batch runs can continue.
    #
    # The output name '<base>-lt4.json' coincides with the LT4 working copy the
    # Data-Fix pipeline materializes from the crawled '<base>.json'. When the
    # output already exists:
    # - results source (any result row): always skipped (SKIP_RESULTS_PRESENT);
    # - previous manifest output (_meta.meeting_only): skipped unless force;
    # - result-free plain working copy with no phase files: backed up and
    #   replaced (the manifest carries the meeting structure, the empty copy doesn't);
    #   with phase files it is skipped unless force (backed up when forced).
    def call(pdf_path, force: false) # rubocop:disable Metrics/AbcSize
      pdf_path = pdf_path.to_s
      warnings = []
      season_id = detect_season_id(pdf_path)
      return Result.new(pdf_path: pdf_path, skipped_reason: "cannot detect season_id from path '#{pdf_path}'") unless season_id.positive?

      out_path = output_path_for(pdf_path, season_id)
      skip_reason = existing_output_skip_reason(out_path, force:)
      return Result.new(pdf_path: pdf_path, skipped_reason: skip_reason) if skip_reason

      text = TextExtractor.new(pdf_path).extract
      extracted, used_model = extract_payload(text, pdf_path, warnings)

      return Result.new(pdf_path: pdf_path, warnings: warnings, skipped_reason: 'extraction failed') if extracted.nil?

      urls = sibling_urls(out_path)
      builder = Lt4Builder.new(extracted: extracted, pdf_path: pdf_path, season_id: season_id, model: used_model, **urls)
      # Retriable issues trigger a single corrective pass with the detected
      # problems fed back to the model (text path only: the completeness
      # heuristic and the feedback prompt both need the manifest text).
      builder = improved_lt4_builder(builder, text:, pdf_path:, season_id:, model: used_model, urls:) if text_payload?(text)
      backup_replaced_output(out_path, warnings)
      FileUtils.mkdir_p(File.dirname(out_path))
      File.write(out_path, JSON.pretty_generate(builder.lt4_hash))

      Result.new(
        pdf_path: pdf_path,
        out_path: out_path,
        warnings: warnings + builder.warnings,
        events_count: Array(builder.lt4_hash['events']).size
      )
    rescue TextExtractor::Error, VisionExtractor::Error, OllamaClient::Error, DevinClient::Error => e
      Result.new(pdf_path: pdf_path, warnings: warnings, skipped_reason: e.message)
    end

    private

    # Season is encoded in the path: 'manifests/<season_id>/file.pdf'.
    # Falls back to the parent dir name when the 'manifests' segment is absent.
    def detect_season_id(pdf_path)
      parts = pdf_path.split('/')
      idx = parts.rindex('manifests')
      idx ? parts[idx + 1].to_i : File.dirname(pdf_path).split('/').last.to_i
    end

    # '<manifests>/<season>/manifest-<date>-<name>.pdf'
    #  => '<results.new>/<season>/<date>-<name>-lt4.json'
    def output_path_for(pdf_path, season_id)
      base = File.basename(pdf_path, '.pdf').sub(/\Amanifest-?/i, '')
      File.join(@results_root, season_id.to_s, "#{base}-lt4.json")
    end

    # Shared source-introspection helpers (layout/result-free detection,
    # backup naming, phase-file naming), memoized per #call.
    def source_resolver
      @source_resolver ||= DataFix::SourceResolver.new
    end

    # Nil when the extraction can proceed and write out_path; otherwise the
    # skip reason (see #call for the decision table).
    def existing_output_skip_reason(out_path, force:)
      @source_resolver = nil # fresh memo: files may have changed since the last call
      return nil unless File.exist?(out_path)
      return "#{SKIP_RESULTS_PRESENT}: #{out_path}" if source_resolver.source_has_result_rows?(out_path)
      return nil if force || replaceable_output?(out_path)

      "#{SKIP_OUTPUT_EXISTS}: #{out_path}"
    end

    # TRUE for a readable, result-free plain working copy (not a previous
    # manifest extraction) with no phase files built on it.
    def replaceable_output?(out_path)
      data = existing_output_data(out_path)
      data.present? && data.dig('_meta', 'meeting_only') != true && phase_files_for(out_path).empty?
    end

    def existing_output_data(out_path)
      data = source_resolver.parsed_source_json(out_path)
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def phase_files_for(out_path)
      (1..5).map { |n| source_resolver.default_phase_path_for(out_path, n) }.select { |path| File.exist?(path) }
    end

    # Any existing output that is not a previous manifest extraction is kept
    # as a '.orig.json' backup before being replaced.
    def backup_replaced_output(out_path, warnings)
      return unless File.exist?(out_path)

      data = existing_output_data(out_path)
      return if data&.dig('_meta', 'meeting_only') == true

      backup_path = source_resolver.next_backup_path_for(out_path)
      FileUtils.cp(out_path, backup_path)
      warnings << "existing result-free source replaced (backup: #{File.basename(backup_path)})"
    end

    # meetingURL / manifestURL from the crawled LT2 sibling '<base>.json' found
    # next to the output, as Lt4Builder keyword args ({} when unavailable).
    def sibling_urls(out_path)
      lt2_path = out_path.sub(/-lt4\.json\z/, '.json')
      return {} if lt2_path == out_path || !File.exist?(lt2_path)

      data = source_resolver.parsed_source_json(lt2_path)
      return {} unless data.is_a?(Hash)

      { meeting_url: data['meetingURL'], manifest_url: data['manifestURL'] }
    rescue StandardError => e
      Rails.logger.warn("[PdfManifests::Extractor] cannot read URLs from #{lt2_path}: #{e.message}")
      {}
    end

    def extract_from_text(text)
      prompt = ExtractionPrompt.build(text)
      @client.generate(prompt: prompt)
    end

    # Returns [extracted_hash, model_used]; falls back to page images when the
    # PDF has no usable text layer.
    def extract_payload(text, pdf_path, warnings)
      return [extract_from_text(text), @client.model] if text_payload?(text)

      warnings << 'no text layer found in PDF'
      extract_from_images(pdf_path, warnings)
    end

    def text_payload?(text)
      text.gsub(/\s+/, '').length >= 100
    end

    # One corrective extraction pass when the normalized build surfaced
    # retriable issues (unknown event codes, dropped/missing program events,
    # bad dates). Keeps the retry output only when it is strictly better:
    # fewer retriable lines and at least as many extracted events.
    def improved_lt4_builder(builder, text:, pdf_path:, season_id:, model:, urls: {}) # rubocop:disable Metrics/ParameterLists
      issue_lines = retriable_issue_lines(builder, text)
      return builder if issue_lines.empty?

      corrected = @client.generate(prompt: ExtractionPrompt.build_correction(text, issue_lines, valid_event_codes))
      retry_builder = Lt4Builder.new(extracted: corrected, pdf_path: pdf_path, season_id: season_id, model:, **urls)
      if retry_improved?(retry_builder, builder, text, issue_lines)
        retry_builder.warnings << "corrective pass applied: #{issue_lines.size} issue(s) reported"
        retry_builder
      else
        builder.warnings << 'corrective extraction pass did not improve the output'
        builder
      end
    rescue OllamaClient::Error, DevinClient::Error => e
      builder.warnings << "corrective extraction pass failed: #{e.message}"
      builder
    end

    def retry_improved?(retry_builder, builder, text, issue_lines)
      retriable_issue_lines(retry_builder, text).size < issue_lines.size &&
        Array(retry_builder.lt4_hash['events']).size >= Array(builder.lt4_hash['events']).size
    end

    # Human-readable retriable lines fed to the corrective prompt: builder
    # issues plus the deterministic program-completeness hints.
    def retriable_issue_lines(builder, text)
      lines = builder.issues.select(&:retriable).map(&:message)
      missing = ProgramScanner.new.missing_mentions(text, builder.lt4_hash['events'])
      lines << "possible missing program events not extracted: #{missing.join(', ')}" if missing.any?
      lines
    end

    def valid_event_codes
      @valid_event_codes ||= GogglesDb::EventType.distinct.pluck(:code).sort
    end

    # Returns [extracted_hash, model_used] or [nil, nil] updating warnings.
    def extract_from_images(pdf_path, warnings)
      unless @client.vision_available?
        warnings << "vision model '#{@client.vision_model}' not available - skipped"
        return [nil, nil]
      end

      images = VisionExtractor.new(pdf_path).to_base64_images
      if images.empty?
        warnings << 'no page images rendered - skipped'
        return [nil, nil]
      end

      warnings << "extracted via vision model '#{@client.vision_model}' (#{images.size} pages)"
      [@client.generate(prompt: ExtractionPrompt.build_for_images, images: images), @client.vision_model]
    rescue VisionExtractor::Error => e
      warnings << e.message
      [nil, nil]
    end
  end
end
