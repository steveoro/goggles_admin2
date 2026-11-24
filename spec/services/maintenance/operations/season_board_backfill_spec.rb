# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::SeasonBoardBackfill do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:, results_acquired: false) }

  before(:each) do
    described_class.data_root = data_root
    health_add_mir(meeting)
  end

  after(:each) do
    described_class.data_root = nil
    FileUtils.rm_rf(data_root)
  end

  it "plans the simulated backfill's SQL with its report as console, with an empty snapshot off the board season" do # rubocop:disable RSpec/MultipleExpectations
    operation = described_class.new(season_id: season.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    backfill = SeasonBoard::Backfill.new(season:, simulate: true, data_root:, snapshot_rows: []).call
    expect(plan.sql_lines).to eq(backfill.sql_log)
    expect(plan.sql_lines.join).to include('results_acquired', "WHERE `id`=#{meeting.id};")
    expect(plan.console).to eq(backfill.report.join("\n"))
    expect(plan.warnings).to eq([I18n.t('maintenance.operations.season_board_backfill.warnings.no_snapshot')])
    expect(plan.summary).to include('season_id' => season.id, 'board_season' => false)
    expect(operation.file_base).to eq("season_board_backfill-#{season.id}")
    expect(Dir.glob(data_root.join('**/*.sql').to_s)).to be_empty
    expect(meeting.reload.results_acquired).to be(false)
  end

  it 'reads the watcher snapshot for the board season' do
    allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
    allow(SeasonBoard::Backfill).to receive(:new).and_call_original
    plan = described_class.new(season_id: season.id).plan
    expect(SeasonBoard::Backfill).to have_received(:new).with(season:, simulate: true, data_root:, snapshot_rows: nil)
    expect(plan.warnings).to be_empty
  end

  it 'gives errors without raising for invalid params and is prefilled from the season finding' do
    expect(described_class.new.plan).to be_blocked
    expect(described_class.new(season_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Season', id: 0)])
    finding = FactoryBot.build(:ops_health_finding, check_key: 'meetings.results_flag', season_id: season.id)
    expect(described_class.from_finding(finding).to_params).to eq('season_id' => season.id)
  end
end
