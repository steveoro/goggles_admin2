# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): the 'fix:*' tasks replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'fix rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'fix:team_in_badge' do
    expect_rake_parity('fix_team_in_badge', 'fix:team_in_badge', data_root:, env: { 'badge' => RakeParity::Fixtures::BADGE_B, 'team' => 1193 })
  end

  it 'fix:team_in_badge without a valid team' do
    expect_rake_parity('fix_team_in_badge_invalid', 'fix:team_in_badge', data_root:, env: { 'badge' => RakeParity::Fixtures::BADGE_B })
  end

  it 'fix:swimmer_in_badge' do
    expect_rake_parity('fix_swimmer_in_badge', 'fix:swimmer_in_badge', data_root:, env: { 'badge' => RakeParity::Fixtures::BADGE_B, 'swimmer' => 142 })
  end

  it 'fix:nil_swimmers_in_results meeting_id=' do
    null_swimmers!(18_315, count: 2)
    expect_rake_parity('fix_nil_swimmers_meeting', 'fix:nil_swimmers_in_results', data_root:, env: { 'meeting_id' => 18_315 })
  end

  it 'fix:nil_swimmers_in_results season_id= (nothing to fix)' do
    expect_rake_parity('fix_nil_swimmers_season', 'fix:nil_swimmers_in_results', data_root:, env: { 'season_id' => 192 })
  end
end
