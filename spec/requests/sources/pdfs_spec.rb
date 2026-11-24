# frozen_string_literal: true

require 'rails_helper'

# PDFs tab, the PDF page and the background scan (ported from the former PDF page specs: odd file names, missing
# file, the log). Nothing runs pdftotext or the parser here (PdfScanJob has its own spec).
RSpec.describe 'Sources PDFs' do
  include ActiveJob::TestHelper

  include_context 'with a Sources data root'

  let(:pdf) { write_data(%(pdfs/242/my "odd" file; touch pwned.pdf), '%PDF') }
  let(:relative) { Sources::FileGuard.new(root: data_root).relative(pdf) }

  def html = response.parsed_body

  it 'lists the PDFs of the season with their TXT, JSON and scan badges' do
    write_data('pdfs/242/a.pdf', '%PDF')
    write_data('pdfs/242/a.txt', 'page')
    write_data('results.new/242/a.json', '{}')
    PdfResults::ScanState.queue!(data_root.join('pdfs/242/a.pdf').to_s)
    get(sources_pdfs_path(season_id: 242))
    row = html.at_css('#sources-pdfs-table tr[data-sources-file="a.pdf"]')
    expect(row.text).to include('TXT', 'JSON', I18n.t('sources.pdfs.scan.badges.queued'))
    expect(row.at_css('a.btn')['href']).to eq(sources_pdf_path(path: 'pdfs/242/a.pdf'))
  end

  describe 'GET /sources/pdfs/show' do
    it 'shows the first TXT page once extracted, and the scan form (a file name with spaces and quotes)' do
      write_data(relative.sub('.pdf', '.txt'), "page one\fpage two")
      get(sources_pdf_path(path: relative))
      expect(response).to have_http_status(:success)
      expect(html.at_css('.sources-txt-preview').text).to eq('page one')
      expect(html.at_css('#frm-sources-pdf-scan input[name="path"]')['value']).to eq(relative)
      expect(html.css('#frm-sources-pdf-scan select[name="ffamily"] option').map(&:text)).to include('1-ficr1')
      expect(html.at_css('#sources-pdf-scan-none')).to be_present
      expect(File).not_to exist(data_root.join('pdfs', '242', 'pwned.pdf'))
    end

    it 'does not extract the text in the request' do
      allow_any_instance_of(Sources::PdfsController).to receive(:system).and_raise('no pdftotext in a request') # rubocop:disable RSpec/AnyInstance
      get(sources_pdf_path(path: relative))
      expect(html.at_css('#sources-pdf-no-txt')).to be_present
    end

    it 'refuses a missing path, a PDF outside pdfs/<season> and one outside the data root' do
      get(sources_pdf_path)
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.blank'))
      get(sources_pdf_path(path: write_data('results.new/242/x.pdf', '%PDF').to_s))
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
      outside = sources_base_dir.join('x.pdf')
      File.write(outside, '%PDF')
      get(sources_pdf_path(path: outside.to_s))
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
    end
  end

  describe 'POST /sources/pdfs/scan' do
    it 'queues a PdfScanJob on the pipeline worker (priority 10) with the scan options, once' do
      expect do
        post(sources_pdf_scan_path, params: { path: relative, ffamily: '1-ficr1', start_page: '2', end_page: '', debug: '1' })
      end.to have_enqueued_job(PdfScanJob).on_queue('pipeline').with(pdf_path: pdf.to_s, ffamily: '1-ficr1', start_page: 2, debug: true)
      expect(enqueued_jobs.last['priority']).to eq(10)
      expect(PdfResults::ScanState.read(pdf)).to have_attributes(status: 'queued', pending?: true)
      expect(response).to redirect_to(sources_pdf_path(path: relative))
      expect { post(sources_pdf_scan_path, params: { path: relative }) }.not_to have_enqueued_job(PdfScanJob)
      expect(flash[:warning]).to eq(I18n.t('sources.pdfs.scan.already_queued'))
    end

    it 'ignores an unknown format family' do
      expect { post(sources_pdf_scan_path, params: { path: relative, ffamily: '../../x' }) }
        .to have_enqueued_job(PdfScanJob).with(pdf_path: pdf.to_s, debug: false)
    end
  end

  describe 'GET /sources/pdfs/scan_result (the frame reloaded while the scan runs)' do
    it 'renders the stored outcome: format table, Data-Fix button and the log' do
      write_data(relative.sub('.pdf', '.log'), "\e[1;32mscan log\e[0m")
      result = PdfResults::ScanRunner::Result.new(
        checked_formats: { '3-finlazio' => { valid: true, last_check: 1, valid_at: [[0, 1]] }, '1-ficr1' => { valid: false, last_check: 0, valid_at: [] } },
        page_count: 2, last_index: 2, result_format_type: '3-finlazio', last_valid_scan: { '3-finlazio' => { 'header' => true } },
        json_path: data_root.join('results.new/242/x.json').to_s, log_path: data_root.join(relative.sub('.pdf', '.log')).to_s,
        txt_path: nil, season_id: 242
      )
      PdfResults::ScanState.finish!(pdf, result)
      get(sources_pdf_scan_result_path(path: relative))
      expect(html.at_css('turbo-frame#sources-pdf-scan')).to be_present
      expect(html.at_css('#sources-pdf-scan-summary').text).to include(I18n.t('sources.pdfs.scan.full_parse', family: '3-finlazio', count: 2))
      expect(html.css('#sources-pdf-scan-formats tbody tr td.fw-semibold').map(&:text)).to eq(%w[3-finlazio 1-ficr1])
      expect(html.at_css('#btn-sources-pdf-data-fix')['href']).to include('/data_fix/review_sessions', 'phase_v2=1')
      expect(html.at_css('.sources-scan-log span.term-fg32')).to be_present
      expect(html.at_css('[data-live-busy="false"]')).to be_present
    end

    it 'says where no format matched, and keeps the busy marker while pending' do
      PdfResults::ScanState.finish!(pdf, PdfResults::ScanRunner::Result.new(checked_formats: {}, page_count: 12, last_index: 2, result_format_type: nil,
                                                                            last_valid_scan: {}, json_path: nil, log_path: nil, txt_path: nil, season_id: 242))
      get(sources_pdf_scan_result_path(path: relative))
      expect(html.at_css('#sources-pdf-scan-summary').text).to include(I18n.t('sources.pdfs.scan.no_match', page: 3, count: 12))
      expect(html.at_css('#btn-sources-pdf-data-fix')).to be_nil
      PdfResults::ScanState.queue!(pdf)
      get(sources_pdf_scan_result_path(path: relative))
      expect(html.at_css('[data-live-busy="true"]')).to be_present
    end
  end
end
