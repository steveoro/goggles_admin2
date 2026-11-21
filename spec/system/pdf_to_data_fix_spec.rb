# frozen_string_literal: true

require 'rails_helper'

# PDF scan -> Data-Fix v2 entry point, on a temporary copy of the "pdf-teamrank-lt2" fixture
# (nothing is ever written into spec/fixtures or crawler/data).
#
# The PDF parsing itself is stubbed (FormatParser + L2Converter, covered by their own specs):
# the scan "produces" the fixture LT2 file, so that the journey checks only the UI wiring.
RSpec.describe 'PDF result card to Data-Fix v2' do
  let(:fixture_path) { Rails.root.join('spec/fixtures/import/pdf-teamrank-lt2.json') }
  let(:fixture_hash) { JSON.parse(File.read(fixture_path)) }
  let(:season) { GogglesDb::Season.find(fixture_hash['season_id']) }
  let(:tmp_root) { Dir.mktmpdir('system-pdf-data-fix-') }
  # (the season ID is read from the folder name; the scan writes the JSON into the sibling 'results.new' folder)
  let(:pdf_path) { File.join(tmp_root, 'pdfs', season.id.to_s, 'pdf-teamrank.pdf') }
  let(:json_path) { File.join(tmp_root, 'results.new', season.id.to_s, 'pdf-teamrank.json') }

  before(:each) do
    FileUtils.mkdir_p(File.dirname(pdf_path))
    FileUtils.touch(pdf_path)
    File.write(pdf_path.sub('.pdf', '.txt'), "7° Trofeo Roma Nuoto Master\n(stubbed text page)\n")
    File.write(pdf_path.sub('.pdf', '.log'), "(stubbed scan log)\n") # (written by the real FormatParser)

    format_parser = instance_double(
      PdfResults::FormatParser,
      scan: nil, pages: ['page 1'], page_index: 1, result_format_type: '3-finlazio', root_dao: nil, season:,
      checked_formats: { '3-finlazio' => { valid: true, last_check: 1, valid_at: [[0]] } },
      last_valid_scan_per_format: {}
    )
    allow(PdfResults::FormatParser).to receive(:new).and_return(format_parser)
    allow(PdfResults::L2Converter).to receive(:new)
      .and_return(instance_double(PdfResults::L2Converter, to_hash: fixture_hash.deep_dup))

    sign_in_admin(prepare_admin_user)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  it 'opens v2 Phase 1 from the DATA-FIX button and shows the team rankings card in Phase 2' do
    visit(pdf_extract_txt_path(file_path: pdf_path))
    click_button('btn-apply-format-scan')

    expect(page).to have_css('#result-card', text: 'FULL PARSE')
    expect(File).to exist(json_path)
    click_link('DATA-FIX')

    # v2 Phase 1 (the first GET builds the phase file and redirects to itself):
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 1')
    expect(page).to have_current_path(/phase_v2=1/)
    expect(page).to have_no_current_path(/legacy/)

    click_link('Step 2 • Teams')

    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 2')
    rankings_count = fixture_hash['sections'].find { |section| section['ranking'] }['rows'].size
    expect(page).to have_css('#phase2-team-scores-card',
                             text: "#{I18n.t('data_import.data_fix.team_scores.title')} (#{rankings_count})")
    expect_no_js_errors
  end
end
