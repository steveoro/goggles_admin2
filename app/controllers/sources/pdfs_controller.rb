# frozen_string_literal: true

module Sources
  #
  # = Sources::PdfsController
  #
  # PDFs tab ('pdfs/<season>'), the page of one PDF (first page of its TXT once extracted, the scan form, the stored
  # scan result) and the scan itself: POST queues a PdfScanJob ('pipeline' worker, priority 10: a queued commit runs
  # first), which extracts the TXT, runs the format parser and stores its outcome in the ops DB (PdfResults::ScanState).
  #
  class PdfsController < BaseController
    # GET /sources/pdfs[?season_id=&focus=]
    def index
      @rows = sources_index.pdfs
    end

    # GET /sources/pdfs/show?path=<pdf>
    def show
      @pdf_path = pdf_path!
      @scan = PdfResults::ScanState.read(@pdf_path)
      @page1 = first_txt_page(@pdf_path.sub_ext('.txt'))
      @format_families = PdfResults::ScanRunner.format_families
    end

    # GET /sources/pdfs/scan_result?path=<pdf> (Turbo frame, reloaded while the scan is queued or running)
    def scan_result
      @pdf_path = pdf_path!
      @scan = PdfResults::ScanState.read(@pdf_path)
      render(layout: false)
    end

    # POST /sources/pdfs/scan (path, ffamily, start_page, end_page, debug)
    def scan
      pdf_path = pdf_path!
      options = scan_options
      if PdfResults::ScanState.read(pdf_path)&.pending?
        flash[:warning] = I18n.t('sources.pdfs.scan.already_queued')
      else
        PdfResults::ScanState.queue!(pdf_path, options)
        PdfScanJob.perform_later(pdf_path: pdf_path.to_s, **options)
        flash[:notice] = I18n.t('sources.pdfs.scan.queued', name: pdf_path.basename)
      end
      redirect_to(sources_pdf_path(path: file_guard.relative(pdf_path)), status: :see_other)
    end

    private

    # Real path of the requested PDF: a .pdf file in 'pdfs/<numeric season>' (raises Refused otherwise).
    def pdf_path!
      path = file_guard.resolve!(params[:path])
      raise Sources::FileGuard::Refused.new(:outside, params[:path]) unless PdfResults::ScanRunner.scannable?(path, root: file_guard.root)

      path
    end

    def scan_options
      {
        ffamily: params[:ffamily].presence&.then { |name| PdfResults::ScanRunner.format_families.include?(name) ? name : nil },
        start_page: params[:start_page].presence&.to_i, end_page: params[:end_page].presence&.to_i,
        debug: ActiveModel::Type::Boolean.new.cast(params[:debug]) || false
      }.compact
    end

    def first_txt_page(txt_path)
      return unless txt_path.file?

      text = File.open(txt_path, 'rb') { |file| file.read(64 * 1024) }.to_s
      text.force_encoding(Encoding::UTF_8).scrub.split("\f").first
    rescue SystemCallError
      nil
    end
  end
end
