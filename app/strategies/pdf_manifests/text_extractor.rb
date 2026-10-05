# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::TextExtractor
  #
  #   - version:  7-0.10.55
  #   - author:   Devin
  #
  # Extracts the text layer from a meeting manifest PDF using the 'pdftotext'
  # utility by the Poppler Developers (same convention as PdfController#extract_txt).
  #
  # The converted '.txt' file is stored as a sibling of the source PDF (it also
  # powers the 'TXT' badge in the file list). When the PDF has no text layer
  # (i.e. it's a scanned image) the text will be empty and #image_only? flags it.
  #
  class TextExtractor
    class Error < StandardError; end

    attr_reader :pdf_path, :txt_path

    def initialize(pdf_path)
      @pdf_path = pdf_path.to_s
      raise Error, "not a PDF file: #{pdf_path}" unless File.exist?(@pdf_path) && @pdf_path.match?(/\.pdf\z/i)

      @txt_path = @pdf_path.sub(/\.pdf\z/i, '.txt')
    end

    # Converts the PDF to text (cached: existing .txt sibling is reused).
    # Returns the extracted text contents (may be empty for scanned PDFs).
    def extract
      unless File.exist?(@txt_path)
        ok = system('pdftotext', '-layout', @pdf_path, @txt_path)
        raise Error, "pdftotext failed on #{@pdf_path}" unless ok
      end
      @text = File.exist?(@txt_path) ? File.read(@txt_path) : ''
    end

    # TRUE when the PDF has no usable text layer (scanned/image-only file).
    # #extract must have been called first.
    def image_only?
      @text.to_s.gsub(/\s+/, '').length < 100
    end
  end
end
