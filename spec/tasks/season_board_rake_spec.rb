# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# 'season_board:backfill' in apply mode passes the DB sync gate first (Drift::Gate, scope :rake), before anything is
# planned (since phase 13 the task runs the 'season_board.backfill' operation through Maintenance::RakeRunner). The
# backfill itself is stubbed (nothing to apply): nothing is written, nothing is run on the DB.
RSpec.describe 'season_board:backfill DB sync gate' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['season_board:backfill'] }
  let(:season) { GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin) }
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:backfill) do
    instance_double(SeasonBoard::Backfill, report: ['report'], statements: [], sql_log: [], resolved: [], unresolved: [])
  end

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('season_board:backfill')
    stub_const('SCRIPT_OUTPUT_DIR', data_root.join('results.new'))
    allow(SeasonBoard::Backfill).to receive(:new).and_return(instance_double(SeasonBoard::Backfill, call: backfill))
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    task.reenable
  end

  after(:each) do
    %w[simulate force season].each { |key| ENV.delete(key) }
    FileUtils.rm_rf(data_root)
    Ops::Database.reset_state!
  end

  def stored(*traits)
    FactoryBot.create(:ops_db_fingerprint, *traits, api_base_url: APIProxy.configured_base_url.to_s.delete_suffix('/'))
  end

  it 'aborts the apply mode on a red verdict, before planning anything' do
    stored(:red)
    ENV['simulate'] = '0'
    expect { task.invoke }.to output(/#{Regexp.escape(I18n.t('db_sync.gate.rake_blocked', summary: 'X').split('(').first)}/).to_stdout
    expect(SeasonBoard::Backfill).not_to have_received(:new)
    expect(Ops::OperationRun.where(operation_key: 'season_board.backfill', origin: 'rake')).to be_empty
  end

  it 'runs the apply mode on a red verdict with force=1 (the dry run plans it: nothing to do here)' do
    stored(:red)
    ENV['simulate'] = '0'
    ENV['force'] = '1'
    expect { task.invoke }.to output(/Nothing to do: all rows are already up to date\.\nDone\./).to_stdout
    expect(SeasonBoard::Backfill).to have_received(:new).with(hash_including(season:, simulate: true))
    expect(Ops::OperationRun.where(operation_key: 'season_board.backfill', origin: 'rake', mode: 'preview').count).to eq(1)
  end

  it 'prints a warning and goes on otherwise (the operator running it acknowledges it)' do
    stored(:amber)
    ENV['simulate'] = '0'
    expect { task.invoke }.to output(/#{Regexp.escape(I18n.t('db_sync.gate.rake_warning', summary: 'X').split('(').first)}/).to_stdout
    expect(SeasonBoard::Backfill).to have_received(:new).with(hash_including(season:, simulate: true))
  end

  it 'never checks in simulate mode (and writes no run: the report and the SQL are only printed)' do
    stored(:red)
    allow(Drift::Gate).to receive(:check)
    expect { task.invoke }.to output(/Done\./).to_stdout
    expect(Drift::Gate).not_to have_received(:check)
    expect(SeasonBoard::Backfill).to have_received(:new).with(hash_including(season:, simulate: true))
    expect(Ops::OperationRun.where(operation_key: 'season_board.backfill')).to be_empty
  end
end
