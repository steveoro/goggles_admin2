# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): 'purge:meeting' replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'purge rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'purge:meeting (confirmed)' do
    expect_rake_parity('purge_meeting', 'purge:meeting', data_root:, env: { 'meeting' => 18_222 }, stdin: "y\n")
  end

  it 'purge:meeting stop_at_events=1 (confirmed)' do
    expect_rake_parity('purge_meeting_stop_at_events', 'purge:meeting', data_root:, env: { 'meeting' => 18_222, 'stop_at_events' => 1 }, stdin: "y\n")
  end

  it 'purge:meeting (not confirmed)' do
    expect_rake_parity('purge_meeting_aborted', 'purge:meeting', data_root:, env: { 'meeting' => 18_222 }, stdin: "\n")
  end
end
