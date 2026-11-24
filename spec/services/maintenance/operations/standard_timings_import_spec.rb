# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::StandardTimingsImport do
  include RakeParity::Fixtures

  let(:dir) { Pathname.new(Dir.mktmpdir('st_import')) }
  let(:source) { standard_timings_xlsx(dir.join('262').to_s, prefix: 'mst_tb_ind_2026-2027') }

  after(:each) { FileUtils.rm_rf(dir) }

  before(:each) { stub_const('Import::StandardTimings::BASE_DIR', dir) }

  it 'plans the rows of Import::StandardTimings without writing; the console holds the former task lines' do
    source
    importer = Import::StandardTimings.new(season: GogglesDb::Season.find(262), base_dir: dir).call
    operation = described_class.new(season_id: 262)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(importer.sql_log)
    expect(plan.write_statements_count).to eq(4)
    expect(plan.console).to include('--> Season 262, 2026/2027', "--> Source file: #{source}.xlsx", '--> Sheet(s) used: VERIFICA',
                                    "--> Read 4 rows. Processing...\n\r\n....")
    expect(plan.summary).to include('rows' => 4, 'inserts' => 4, 'sheets' => ['VERIFICA'])
  end

  it 'goes to the season folder and starts held until the remote season exists (after a local apply)' do
    operation = described_class.new(season_id: 262)
    expect(operation.outbox_folder).to eq('262')
    expect(operation.held_reason).to eq('remote_season_missing')
    expect(Ops::SqlScript::HELD_REASONS).to include('remote_season_missing')
    expect(operation.file_base).to eq('262-standard_timings')
  end

  it 'stops on the validity errors before any SQL' do
    stub_const('RakeParity::Fixtures::XLSX_ROWS', [['M99', 'A1', '50 STILE LIBERO', 'X', '33', 2850, '002850', "0'28\"50"]])
    source
    plan = described_class.new(season_id: 262).plan
    expect(plan.sql_lines).to be_empty
    expect(plan.errors).to contain_exactly("category_code 'M99' not found among CategoryTypes for season 262",
                                           "unknown gender code 'X'", "unknown pool_type code '33'")
  end
end
