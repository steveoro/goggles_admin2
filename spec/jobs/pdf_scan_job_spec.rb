# frozen_string_literal: true

require 'rails_helper'

# Phase 15: the PDF scan as a job (formerly the synchronous PdfController#scan). The real FormatParser runs on a
# fixture TXT (spec/fixtures/pdfs/unknown-format.txt, matching no format) copied under a temporary
# '<root>/pdfs/242/' folder; the "full parse" path stubs the parser and the L2 converter (as the former system
# journey did). pdftotext never runs: the TXT is there already, or the system call is stubbed.
RSpec.describe PdfScanJob do
  let(:data_root) { Pathname.new(Dir.mktmpdir('pdf-scan-job-')).realpath }
  let(:pdf_path) { data_root.join('pdfs', '242', 'sample.pdf') }
  let(:txt_path) { pdf_path.sub_ext('.txt') }

  def perform(**options) = described_class.perform_now(pdf_path: pdf_path.to_s, **options)

  def state = PdfResults::ScanState.read(pdf_path)

  before(:each) do
    FileUtils.mkdir_p(pdf_path.dirname)
    File.write(pdf_path, '%PDF')
    described_class.data_dir = data_root
    allow(ActionCable.server).to receive(:broadcast)
    # (the format parser prints its progress on the console)
    allow($stdout).to receive_messages(write: 0, puts: nil)
  end

  after(:each) do
    described_class.data_dir = nil
    FileUtils.rm_rf(data_root)
  end

  it 'runs on the pipeline worker with priority 10, without retry handlers' do
    job = described_class.new(pdf_path: 'x')
    expect(job.queue_name).to eq('pipeline')
    expect(job.priority).to eq(10)
    expect(described_class.rescue_handlers).to be_empty
  end

  context 'with the fixture TXT (no format matches)' do
    before(:each) { FileUtils.cp(file_fixture('pdfs/unknown-format.txt'), txt_path) }

    it 'stores the same checked formats as a direct FormatParser scan with the former controller arguments' do
      perform
      expected = PdfResults::FormatParser.new(txt_path.to_s, verbose_log: false, debug: false)
      expected.scan(ffamily_filter: nil, limit_pages: nil)
      expect(state).to have_attributes(status: 'done', full_parse?: false, page_count: expected.pages.count, last_index: expected.page_index,
                                       result_format_type: nil, json_path: nil)
      expect(state.checked_formats).to eq(JSON.parse(expected.checked_formats.to_json))
      expect(state.checked_formats.keys).to include(*PdfResults::ScanRunner.format_families.first(3).map { |family| a_string_starting_with(family) })
      expect(state.label).to eq(I18n.t('sources.pdfs.scan.states.stopped', page: expected.page_index + 1, count: expected.pages.count))
      expect(state.log_path).to eq(data_root.join('pdfs', '242', 'sample.log').to_s)
      expect(File).to exist(state.log_path)
      expect(data_root.join('results.new')).not_to exist
    end

    it 'keeps the format family filter and the page range' do
      perform(ffamily: '1-ficr1', start_page: 0, end_page: 0)
      expect(state.checked_formats.keys).to all(start_with('1-ficr1'))
      expect(state.options).to include('ffamily' => '1-ficr1', 'start_page' => 0, 'end_page' => 0)
    end

    it 'pings the open PDF pages and records the event' do
      perform
      expect(ActionCable.server).to have_received(:broadcast).with(AppNotificationsChannel::STREAM, { dom_id: described_class::NOTIFY_DOM_ID, html: '' })
      event = Ops::Event.where(kind: 'sources.pdf_scan_finished', subject_key: 'sample.pdf').last
      expect(event).to have_attributes(level: 'warning', season_id: 242, link_path: '/sources/pdfs/show?path=pdfs%2F242%2Fsample.pdf')
    end
  end

  it 'writes the LT2 JSON in results.new/<season> on a full parse, filling the blank team names' do
    File.write(txt_path, 'text')
    season = GogglesDb::Season.find(242)
    parser = instance_double(
      PdfResults::FormatParser, scan: nil, pages: ['page 1'], page_index: 1, result_format_type: '3-finlazio', root_dao: nil, season:,
                                checked_formats: { '3-finlazio' => { valid: true, last_check: 1, valid_at: [[0]] } },
                                last_valid_scan_per_format: {}
    )
    allow(PdfResults::FormatParser).to receive(:new).and_return(parser)
    l2 = { 'sections' => [{ 'rows' => [{ 'name' => 'ROSSI MARIO', 'year' => '1970', 'sex' => 'M', 'team' => '' },
                                       { 'name' => 'ROSSI MARIO', 'year' => '1970', 'sex' => 'M', 'team' => 'Nuoto Club' }] }] }
    allow(PdfResults::L2Converter).to receive(:new).and_return(instance_double(PdfResults::L2Converter, to_hash: l2))
    perform
    json_path = data_root.join('results.new', '242', 'sample.json')
    expect(state).to have_attributes(status: 'done', full_parse?: true, json_path: json_path.to_s)
    expect(JSON.parse(File.read(json_path)).dig('sections', 0, 'rows').pluck('team')).to eq(['Nuoto Club', 'Nuoto Club'])
  end

  it 'extracts the TXT with pdftotext (separate arguments, no shell) when missing' do
    odd = pdf_path.dirname.join(%(my "odd" file; touch pwned.pdf))
    File.write(odd, '%PDF')
    allow_any_instance_of(PdfResults::ScanRunner).to receive(:system) do |_runner, *args| # rubocop:disable RSpec/AnyInstance
      expect(args).to eq(['pdftotext', '-layout', odd.to_s, odd.sub_ext('.txt').to_s])
      FileUtils.cp(file_fixture('pdfs/unknown-format.txt'), odd.sub_ext('.txt'))
      true
    end
    described_class.perform_now(pdf_path: odd.to_s)
    expect(PdfResults::ScanState.read(odd)).to have_attributes(status: 'done')
    expect(File).not_to exist(pdf_path.dirname.join('pwned.pdf'))
  end

  it 'stores a failure (refused path, missing text) without raising' do
    other = data_root.join('results.new', '242', 'x.pdf')
    FileUtils.mkdir_p(other.dirname)
    File.write(other, '%PDF')
    expect { described_class.perform_now(pdf_path: other.to_s) }.not_to raise_error
    expect(PdfResults::ScanState.read(other)).to have_attributes(status: 'failed', error: start_with('PdfResults::ScanRunner::Refused'))

    allow_any_instance_of(PdfResults::ScanRunner).to receive(:system).and_return(false) # rubocop:disable RSpec/AnyInstance
    perform
    expect(state).to have_attributes(status: 'failed', error: include('pdftotext produced no text'))
    expect(Ops::Event.where(kind: 'sources.pdf_scan_failed', subject_key: 'sample.pdf')).to exist
  end
end
