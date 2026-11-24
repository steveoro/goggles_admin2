# frozen_string_literal: true

require 'rails_helper'

# Rake parity (phase 13): 'normalize:coded_names' replayed on the recorded baselines (see spec/support/rake_parity).
RSpec.describe 'normalize rake tasks parity', :rake_parity do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('rake_parity')) }

  before(:each) { hide_leftover_seasons! }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'normalize:coded_names limit=25 (two meeting codes to normalize)' do
    ids = GogglesDb::Meeting.order(:id).limit(2).pluck(:id)
    GogglesDb::Meeting.where(id: ids).update_all(code: 'parity-not-normalized') # rubocop:disable Rails/SkipsModelValidations
    expect_rake_parity('normalize_coded_names_changes', 'normalize:coded_names', data_root:, env: { 'limit' => 25 })
  end

  # Deviation (phase 13): a batch without any change writes no script any more (the operations refuse an empty plan);
  # the output is the baseline's up to the statistics, then the "nothing to do" line.
  it 'normalize:coded_names limit=25 (nothing to normalize): same report, no empty script' do
    skip('reference of the former task: never re-recorded') if RakeParity.record?
    run = rake_parity_run('normalize:coded_names', data_root:, env: { 'limit' => 25 })
    baseline_output, baseline_scripts = RakeParity.baseline_parts('normalize_coded_names')
    expect(baseline_scripts.size).to eq(1)
    report = baseline_output[/\A.*-- Stats: [^\n]*\n/m]
    expect(RakeParity.normalize(run.output, data_root:)).to eq("#{report}#{I18n.t('maintenance.rake.nothing_to_do')}\n")
    expect(run.scripts).to be_empty
    expect(run.exit_status).to be_nil
  end
end
