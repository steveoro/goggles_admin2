# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): the 'merge:*' tasks replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'merge rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'merge:swimmer (checker issues: aborted)' do
    expect_rake_parity('merge_swimmer', 'merge:swimmer', data_root:, env: { 'src' => 142, 'dest' => 23 })
  end

  it 'merge:swimmer force=1' do
    expect_rake_parity('merge_swimmer_force', 'merge:swimmer', data_root:, env: { 'src' => 142, 'dest' => 23, 'force' => 1 })
  end

  it 'merge:swimmer without valid ids' do
    expect_rake_parity('merge_swimmer_invalid', 'merge:swimmer', data_root:, env: { 'src' => 0, 'dest' => 23 })
  end

  it 'merge:team' do
    expect_rake_parity('merge_team', 'merge:team', data_root:, env: { 'src' => 1, 'dest' => 2 })
  end

  it 'merge:meeting' do
    expect_rake_parity('merge_meeting', 'merge:meeting', data_root:, env: { 'src' => 1, 'dest' => 5 })
  end

  it 'merge:badge (sure duplicate on the same team)' do
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    move_mirs(RakeParity::Fixtures::BADGE_A, copy, count: 2)
    expect_rake_parity('merge_badge', 'merge:badge', data_root:, env: { 'src' => copy.id, 'dest' => RakeParity::Fixtures::BADGE_A },
                                                     tokens: { 'BADGE_COPY' => copy.id })
  end

  it 'merge:badge autofix=1 (relay category, no destination)' do
    relay_category!(RakeParity::Fixtures::BADGE_B)
    expect_rake_parity('merge_badge_autofix', 'merge:badge', data_root:, env: { 'src' => RakeParity::Fixtures::BADGE_B, 'autofix' => 1 })
  end

  it 'merge:team_in_1_meeting (confirmed)' do
    expect_rake_parity('merge_team_in_1_meeting', 'merge:team_in_1_meeting', data_root:,
                                                                             env: { 'meeting' => 18_289, 'src' => 913, 'dest' => 1270 }, stdin: "y\n")
  end

  it 'merge:team_in_1_meeting (not confirmed)' do
    expect_rake_parity('merge_team_in_1_meeting_no', 'merge:team_in_1_meeting', data_root:,
                                                                                env: { 'meeting' => 18_289, 'src' => 913, 'dest' => 1270 }, stdin: "n\n")
  end

  # Behaviour changed by the phase-13 decisions (one script per step, every badge in its own transaction inside it;
  # simulate=1 is now the default): the baseline was recorded with the former task, which applied every badge script
  # at once (here: through ActiveRecord, inside the spec transaction). Replayed with simulate=0 and the same stand-in,
  # each former per-badge script must appear verbatim, in order, inside the step scripts; the header lines are equal.
  it 'merge:season_fix src_team= (one sure duplicate, one relay-only badge): same badge SQL, one script per step' do
    skip('reference of the former task: never re-recorded') if RakeParity.record?
    allow(LocalDb::SqlRunner).to receive(:call) do |path:|
      maintenance_statements(File.read(path)).each { |sql| ActiveRecord::Base.connection.execute(sql) }
      LocalDb::SqlRunner::Result.new(success: true, stdout: '', stderr: '', duration: 0.01, exit_code: 0)
    end
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    move_mirs(RakeParity::Fixtures::BADGE_A, copy, count: 2)
    relay_category!(RakeParity::Fixtures::BADGE_B)
    tokens = { 'BADGE_COPY' => copy.id }
    run = rake_parity_run('merge:season_fix', data_root:, env: { 'season' => 182, 'src_team' => RakeParity::Fixtures::TEAM_A, 'simulate' => 0 })

    baseline_output, baseline_scripts = RakeParity.baseline_parts('merge_season_fix')
    output = RakeParity.normalize(run.output, data_root:, tokens:)
    header = baseline_output[/\A.*--> Running BadgeSeasonChecker to collect candidates\.\.\.\n/m]
    expect(output).to start_with(header)
    scripts = run.scripts.map { |rel_path, sql| [RakeParity.normalize(rel_path, data_root:, tokens:), RakeParity.normalize(sql, data_root:, tokens:)] }
    expect(scripts.map(&:first)).to eq(%w[results.new/misc/NNNN-season_fix_182-step1-sure.sql results.new/misc/NNNN-season_fix_182-step2-relay_only.sql])
    baseline_scripts.zip(scripts).each do |(old_rel_path, old_sql), (_rel_path, sql)|
      expect(sql).to include(old_sql.chomp), old_rel_path
    end
    expect(output).to include("--> Step 1: 'sure badge merges': 1. Preparing SQL script...", "--> Step 2: 'relay-only' badges: 1. Preparing SQL script...",
                              '--> Executing script...', "Done.\n")
  end
end
