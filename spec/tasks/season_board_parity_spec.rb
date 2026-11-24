# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): 'season_board:backfill' (simulate) replayed on the recorded baseline
# (see spec/support/rake_parity). The crawl files and the watcher snapshot come from an empty temporary data root.
RSpec.describe 'season_board rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) do
    hide_leftover_seasons!
    stub_const('SeasonBoard::Backfill::DEFAULT_DATA_ROOT', data_root)
    allow(FedernuotoWatch::StateStore).to receive(:new).and_return(instance_double(FedernuotoWatch::StateStore, read: {}))
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'season_board:backfill season= (simulate)' do
    expect_rake_parity('season_board_backfill', 'season_board:backfill', data_root:, env: { 'season' => 182 })
  end
end
