# frozen_string_literal: true

module Sources
  #
  # = Sources::PdfScanResultComponent
  #
  # The stored outcome of the last scan of a PDF (PdfResults::ScanState): queued / running (busy marker for the
  # live-frames reload), failed (the error), or done: "parsed" (every page matched a format: "Open in Data-Fix" on the
  # JSON written) or "no format matched at page N", with the table of the checked formats (valid or not, last checked
  # page, valid pages, the contexts of the last valid scan) and the parser log.
  #
  class PdfScanResultComponent < ViewComponent::Base
    # Max bytes of the parser log shown (its tail).
    LOG_TAIL_BYTES = 256 * 1024

    # - scan: the PdfResults::ScanState (or nil: never scanned); pdf_path: the PDF (real path).
    def initialize(scan:, pdf_path:)
      super()
      @scan = scan
      @pdf_path = Pathname.new(pdf_path)
    end

    protected

    def pending? = @scan&.pending?

    def status_class
      return 'text-bg-secondary' unless @scan

      "text-bg-#{@scan.tone}"
    end

    def status_text = @scan ? @scan.label : t('sources.pdfs.scan.states.none')

    def time_text
      time = @scan&.finished_at || @scan&.started_at || @scan&.queued_at
      time ? l(time.localtime, format: :short) : nil
    end

    def checked_formats = @scan&.checked_formats || {}

    def last_valid_scan = @scan&.last_valid_scan || {}

    def valid_pages(result)
      Array(result['valid_at']).flatten.uniq.join(', ')
    end

    def data_fix_path
      helpers.review_sessions_path(file_path: @scan.json_path, phase_v2: 1) if @scan&.full_parse? && @scan.json_path
    end

    def log_path
      path = @scan&.log_path.presence || @pdf_path.dirname.join("#{@pdf_path.basename.to_s.split('.').first}.log").to_s
      File.file?(path) ? path : nil
    end

    # The tail of the parser log, rendered from its ANSI colours (Terminal escapes the text).
    def log_html
      path = log_path
      return unless path

      size = File.size(path)
      text = File.open(path, 'rb') do |file|
        file.seek([size - LOG_TAIL_BYTES, 0].max)
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub
      end
      Terminal.render(text).html_safe # rubocop:disable Rails/OutputSafety
    rescue SystemCallError
      nil
    end

    def log_toggle_attributes
      { type: 'button', 'aria-expanded' => 'false', 'aria-controls' => 'sources-pdf-scan-log',
        data: { bs_toggle: 'collapse', bs_target: '#sources-pdf-scan-log' } }
    end

    def log_name = File.basename(log_path.to_s)

    def log_size = log_path ? File.size(log_path) : 0

    def log_truncated? = log_size > LOG_TAIL_BYTES
  end
end
