# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): the 'check:*' tasks replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'check rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  # (check:results and check:events order the meetings by date only: the output lines are compared sorted)
  it('check:results') { expect_rake_parity('check_results', 'check:results', data_root:, env: { 'season' => 182 }, sorted: true) }

  it 'check:results mrr presence' do
    expect_rake_parity('check_results_mrr_presence', 'check:results', data_root:, env: { 'season' => 182, 'mrr' => 1, 'presence' => 1 }, sorted: true)
  end

  it('check:results (default season)') { expect_rake_parity('check_results_default', 'check:results', data_root:, sorted: true) }

  it('check:events') { expect_rake_parity('check_events', 'check:events', data_root:, env: { 'season' => 182 }, sorted: true) }

  it('check:team') { expect_rake_parity('check_team', 'check:team', data_root:, env: { 'src' => 1, 'dest' => 2 }) }

  it('check:swimmer') { expect_rake_parity('check_swimmer', 'check:swimmer', data_root:, env: { 'src' => 142, 'dest' => 23 }) }

  it 'check:badge' do
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    expect_rake_parity('check_badge', 'check:badge', data_root:, env: { 'src' => copy.id, 'dest' => RakeParity::Fixtures::BADGE_A },
                                                     tokens: { 'BADGE_COPY' => copy.id })
  end

  it 'check:season list_teams=1' do
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    relay_category!(RakeParity::Fixtures::BADGE_B)
    expect_rake_parity('check_season', 'check:season', data_root:, env: { 'season' => 182, 'list_teams' => 1 }, tokens: { 'BADGE_COPY' => copy.id })
  end

  it 'check:map_team_badges' do
    expect_rake_parity('check_map_team_badges', 'check:map_team_badges', data_root:, env: { 'season' => 182, 'team' => 54, 'page' => 0 })
  end

  it 'check:map_swimmer_mirs' do
    expect_rake_parity('check_map_swimmer_mirs', 'check:map_swimmer_mirs', data_root:, env: { 'swimmer' => 142, 'page' => 0 })
  end

  it('check:dup_badges_for_team') { expect_rake_parity('check_dup_badges_for_team', 'check:dup_badges_for_team', data_root:, env: { 'team' => 54 }) }

  it 'check:dup_mir_badges' do
    duplicate_mir(18_222)
    expect_rake_parity('check_dup_mir_badges', 'check:dup_mir_badges', data_root:, env: { 'meeting_id' => 18_222 })
  end

  it 'check:dup_mir_swimmers (report only)' do
    copy = duplicate_mir(18_222)
    expect_rake_parity('check_dup_mir_swimmers_report', 'check:dup_mir_swimmers', data_root:, env: { 'meeting_id' => 18_222 },
                                                                                  tokens: { 'MIR_COPY' => copy.id })
  end

  it 'check:dup_mir_swimmers autofix=1 (confirmed)' do
    copy = duplicate_mir(18_222)
    expect_rake_parity('check_dup_mir_swimmers_autofix', 'check:dup_mir_swimmers', data_root:, env: { 'meeting_id' => 18_222, 'autofix' => 1 },
                                                                                   stdin: "y\n", tokens: { 'MIR_COPY' => copy.id })
  end
end
