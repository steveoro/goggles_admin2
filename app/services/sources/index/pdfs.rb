# frozen_string_literal: true

module Sources
  class Index
    #
    # = Sources::Index::Pdfs
    #
    # Rows of the PDFs tab: the PDFs in 'pdfs/<season>', with their TXT (pdftotext output), their JSON (the LT2
    # source a full scan writes in 'results.new/<season>/<base>.json') and the state of their last scan
    # (Ops::Snapshot 'pdf_scan:<sha1>', see PdfScanJob). The primary action opens the PDF page (preview, scan form
    # and scan result).
    #
    class Pdfs
      def initialize(index)
        @index = index
      end

      def rows
        @index.files_in('pdfs', '*.pdf').map do |path|
          @index.file_row(path, badges: badges(path), primary: open_action(path))
        end
      end

      private

      def badges(path)
        txt = path.sub_ext('.txt')
        json = @index.season_dir('results.new').join(path.basename.sub_ext('.json'))
        [
          (Badge.new(label: 'TXT', tone: 'secondary', title: I18n.t('sources.pdfs.badges.txt')) if txt.file?),
          (Badge.new(label: 'JSON', tone: 'success', title: I18n.t('sources.pdfs.badges.json')) if json.file?),
          scan_badge(path)
        ].compact
      end

      def scan_badge(path)
        scan = PdfResults::ScanState.read(path)
        return unless scan

        Badge.new(label: scan.short_label, tone: scan.tone, title: scan.label)
      end

      def open_action(path)
        RowAction.new(label: I18n.t('sources.pdfs.actions.open'), icon: 'fa-magnifying-glass',
                      path: @index.url_helpers.sources_pdf_path(path: @index.relative(path)))
      end
    end
  end
end
