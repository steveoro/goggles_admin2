# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): 'recompute:ranks' replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'recompute rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'recompute:ranks meeting= (two ranks swapped)' do
    first, second = GogglesDb::MeetingIndividualResult.joins(meeting_program: { meeting_event: :meeting_session })
                                                      .where(meeting_sessions: { meeting_id: 18_211 }, disqualified: false)
                                                      .where('meeting_individual_results.rank > 0').order(:id).first(2)
    first.update_columns(rank: second.rank) # rubocop:disable Rails/SkipsModelValidations
    second.update_columns(rank: 0) # rubocop:disable Rails/SkipsModelValidations
    expect_rake_parity('recompute_ranks_meeting', 'recompute:ranks', data_root:, env: { 'meeting' => 18_211 })
  end
end
