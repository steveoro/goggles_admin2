# frozen_string_literal: true

require 'base64'
require 'tmpdir'

module PdfManifests
  # = PdfManifests::VisionExtractor
  #
  #   - version:  7-0.10.55
  #   - author:   Devin
  #
  # Fallback for scanned/image-only manifest PDFs: renders each page to PNG
  # with 'pdftoppm' and lets a vision-capable Ollama model extract the data.
  #
  # Used only when TextExtractor finds no text layer AND the configured vision
  # model is actually installed (checked via OllamaClient#vision_available?).
  #
  class VisionExtractor
    class Error < StandardError; end

    # Render resolution for pdftoppm (DPI). 150 keeps images readable yet small.
    RENDER_DPI = 150

    # Max number of pages sent to the model (manifests are typically 1-4 pages).
    MAX_PAGES = 6

    attr_reader :pdf_path

    def initialize(pdf_path)
      @pdf_path = pdf_path.to_s
      raise Error, "not a PDF file: #{pdf_path}" unless File.exist?(@pdf_path)
    end

    # TRUE when pdftoppm is available on PATH.
    def self.available?
      system('which pdftoppm > /dev/null 2>&1')
    end

    # Renders the PDF pages and returns an Array of base64-encoded PNG images
    # suitable for Ollama's 'images' parameter.
    def to_base64_images
      raise Error, 'pdftoppm not found on PATH' unless self.class.available?

      Dir.mktmpdir('pdf_manifest') do |dir|
        prefix = File.join(dir, 'page')
        ok = system('pdftoppm', '-png', '-r', RENDER_DPI.to_s, '-l', MAX_PAGES.to_s, @pdf_path, prefix)
        raise Error, "pdftoppm failed on #{@pdf_path}" unless ok

        return Dir.glob("#{prefix}-*.png").map { |img| Base64.strict_encode64(File.binread(img)) }
      end
    end
  end
end
