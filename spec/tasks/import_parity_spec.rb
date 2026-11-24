# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): 'import:categories' and 'import:standard_timings' replayed on the recorded baselines
# (see spec/support/rake_parity).
RSpec.describe 'import rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'import:categories remove=' do
    expect_rake_parity('import_categories', 'import:categories', data_root:, env: { 'src' => 252, 'dest' => 262, 'remove' => 'M25,U20' })
  end

  it 'import:standard_timings source=' do
    source = standard_timings_xlsx(data_root.join('standard_timings_src').to_s)
    expect_rake_parity('import_standard_timings', 'import:standard_timings', data_root:, env: { 'season' => 262, 'source' => source })
  end

  it 'import:standard_timings with an unknown season' do
    expect_rake_parity('import_standard_timings_invalid', 'import:standard_timings', data_root:, env: { 'season' => 1 })
  end
end
