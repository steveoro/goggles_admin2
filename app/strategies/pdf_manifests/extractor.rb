# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::Extractor
  #
  #   - version:  7-0.10.55
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
  class Extractor
    class Error < StandardError; end

    # Returned per processed file.
    Result = Struct.new(:pdf_path, :out_path, :warnings, :events_count, :skipped_reason, keyword_init: true) do
      def success?
        out_path.present?
      end
    end

    def initialize(client: OllamaClient.new)
      @client = client
    end

    # Processes a single manifest PDF and writes the LT4 source file under
    # 'crawler/data/results.new/<season_id>/'.
    #
    # Never raises for data-level problems: failures are returned inside
    # Result#skipped_reason so batch runs can continue.
    def call(pdf_path, force: false) # rubocop:disable Metrics/AbcSize
      pdf_path = pdf_path.to_s
      warnings = []
      season_id = detect_season_id(pdf_path)
      return Result.new(pdf_path: pdf_path, skipped_reason: "cannot detect season_id from path '#{pdf_path}'") unless season_id.positive?

      out_path = output_path_for(pdf_path, season_id)

      return Result.new(pdf_path: pdf_path, skipped_reason: "output already exists: #{out_path}") if File.exist?(out_path) && !force

      text = TextExtractor.new(pdf_path).extract
      extracted, used_model = extract_payload(text, pdf_path, warnings)

      return Result.new(pdf_path: pdf_path, warnings: warnings, skipped_reason: 'extraction failed') if extracted.nil?

      builder = Lt4Builder.new(extracted: extracted, pdf_path: pdf_path, season_id: season_id, model: used_model)
      # Retriable issues trigger a single corrective pass with the detected
      # problems fed back to the model (text path only: the completeness
      # heuristic and the feedback prompt both need the manifest text).
      builder = improved_lt4_builder(builder, text:, pdf_path:, season_id:, model: used_model) if text_payload?(text)
      FileUtils.mkdir_p(File.dirname(out_path))
      File.write(out_path, JSON.pretty_generate(builder.lt4_hash))

      Result.new(
        pdf_path: pdf_path,
        out_path: out_path,
        warnings: warnings + builder.warnings,
        events_count: Array(builder.lt4_hash['events']).size
      )
    rescue TextExtractor::Error, VisionExtractor::Error, OllamaClient::Error => e
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
      Rails.root.join('crawler', 'data', 'results.new', season_id.to_s, "#{base}-lt4.json").to_s
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
    def improved_lt4_builder(builder, text:, pdf_path:, season_id:, model:)
      issue_lines = retriable_issue_lines(builder, text)
      return builder if issue_lines.empty?

      corrected = @client.generate(prompt: ExtractionPrompt.build_correction(text, issue_lines, valid_event_codes))
      retry_builder = Lt4Builder.new(extracted: corrected, pdf_path: pdf_path, season_id: season_id, model:)
      if retry_improved?(retry_builder, builder, text, issue_lines)
        retry_builder.warnings << "corrective pass applied: #{issue_lines.size} issue(s) reported"
        retry_builder
      else
        builder.warnings << 'corrective extraction pass did not improve the output'
        builder
      end
    rescue OllamaClient::Error => e
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
