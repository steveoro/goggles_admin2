# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::StandardTimings do
  include RakeParity::Fixtures

  let(:season) { GogglesDb::Season.find(262) }
  let(:dir) { Pathname.new(Dir.mktmpdir('st_strategy')) }

  after(:each) { FileUtils.rm_rf(dir) }

  it 'builds the same rows as the former rake task (recorded baseline of import:standard_timings)' do
    source = standard_timings_xlsx(dir.to_s)
    events = []
    importer = described_class.new(season:, source:, base_dir: dir).call { |event, value| events << [event, value] }
    _output, scripts = RakeParity.baseline_parts('import_standard_timings')
    expect(Maintenance::RakeRunner::SCRIPT_TEXT.call(Struct.new(:sql_lines).new(importer.sql_log))).to eq(scripts.sole.last)
    expect(importer.errors).to be_empty
    expect(importer).to have_attributes(inserts_count: 4, skipped_count: 0, sheets_used: ['VERIFICA'])
    expect(events.map(&:first)).to eq(%i[source sheets read row row row row])
  end

  it 'finds the season file by itself ("*mst_tb_ind*<begin year>*.xlsx" in the season folder)' do
    standard_timings_xlsx(dir.join('262').to_s, prefix: "x_mst_tb_ind_#{season.begin_date.year}")
    expect(described_class.new(season:, base_dir: dir).resolve_source_filename.to_s).to end_with("262/x_mst_tb_ind_#{season.begin_date.year}.xlsx")
    expect(described_class.new(season:, base_dir: dir.join('none')).call.errors.sole).to start_with("Can't find a suitable source file")
  end

  it 'stops on the validity errors before any SQL' do
    stub_const('RakeParity::Fixtures::XLSX_ROWS', [['M99', 'A1', '50 STILE LIBERO', 'M', '25', 2850, '002850', "0'28\"50"],
                                                   ['M25', 'A2', '50 NUOTATA', 'M', '25', 2850, '002850', "0'28\"50"]])
    importer = described_class.new(season:, source: standard_timings_xlsx(dir.to_s), base_dir: dir).call
    expect(importer.sql_log).to be_empty
    expect(importer.validity_errors).to eq(["category_code 'M99' not found among CategoryTypes for season 262",
                                            "unknown event_type code '50 NUOTATA' (from event_label)"])
  end
end
