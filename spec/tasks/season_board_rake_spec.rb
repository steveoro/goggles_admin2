# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# 'season_board:backfill' in apply mode passes the DB sync gate first (Drift::Gate, scope :rake). The backfill itself
# is stubbed: nothing is written, nothing is run on the DB.
RSpec.describe 'season_board:backfill DB sync gate' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['season_board:backfill'] }
  let(:season) { GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin) }
  let(:backfill) { instance_double(SeasonBoard::Backfill, report: ['report'], statements: [], sql_log: []) }

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('season_board:backfill')
    allow(SeasonBoard::Backfill).to receive(:new).and_return(instance_double(SeasonBoard::Backfill, call: backfill))
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    task.reenable
  end

  after(:each) do
    %w[simulate force season].each { |key| ENV.delete(key) }
    Ops::Database.reset_state!
  end

  def stored(*traits)
    FactoryBot.create(:ops_db_fingerprint, *traits, api_base_url: APIProxy.configured_base_url.to_s.delete_suffix('/'))
  end

  it 'aborts the apply mode on a red verdict' do
    stored(:red)
    ENV['simulate'] = '0'
    expect { task.invoke }.to output(/#{Regexp.escape(I18n.t('db_sync.gate.rake_blocked', summary: 'X').split('(').first)}/).to_stdout
    expect(SeasonBoard::Backfill).not_to have_received(:new)
  end

  it 'runs the apply mode on a red verdict with force=1' do
    stored(:red)
    ENV['simulate'] = '0'
    ENV['force'] = '1'
    expect { task.invoke }.to output(/Done\./).to_stdout
    expect(SeasonBoard::Backfill).to have_received(:new).with(season:, simulate: false)
  end

  it 'prints a warning and goes on otherwise (the operator running it acknowledges it)' do
    stored(:amber)
    ENV['simulate'] = '0'
    expect { task.invoke }.to output(/#{Regexp.escape(I18n.t('db_sync.gate.rake_warning', summary: 'X').split('(').first)}/).to_stdout
    expect(SeasonBoard::Backfill).to have_received(:new).with(season:, simulate: false)
  end

  it 'never checks in simulate mode' do
    stored(:red)
    allow(Drift::Gate).to receive(:check)
    expect { task.invoke }.to output(/Done\./).to_stdout
    expect(Drift::Gate).not_to have_received(:check)
    expect(SeasonBoard::Backfill).to have_received(:new).with(season:, simulate: true)
  end
end
