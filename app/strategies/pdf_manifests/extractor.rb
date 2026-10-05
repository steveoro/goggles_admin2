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
      extracted = nil
      used_model = nil

      if text.gsub(/\s+/, '').length >= 100
        extracted = extract_from_text(text)
        used_model = @client.model
      else
        warnings << 'no text layer found in PDF'
        extracted, used_model = extract_from_images(pdf_path, warnings)
      end

      return Result.new(pdf_path: pdf_path, warnings: warnings, skipped_reason: 'extraction failed') if extracted.nil?

      builder = Lt4Builder.new(extracted: extracted, pdf_path: pdf_path, season_id: season_id, model: used_model)
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
