# frozen_string_literal: true

require 'rails_helper'

# (phase 09) Phase5Populator hardening: a cross-source import_key collision is reported (never silently reusing the
# other source's row), the parity check reports the rows that could not be staged, the repopulate runs in one
# transaction and the existing phase5 '_meta' is kept.
RSpec.describe Import::Phase5Populator, type: :strategy do
  let(:fixtures_dir) { Rails.root.join('spec/fixtures/import') }
  let(:basename) { 'sample-200RA-l4' }
  let(:tmp_root) { Dir.mktmpdir('populator-collision-') }
  let(:work_dir) { File.join(tmp_root, '242').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_path) { File.join(work_dir, "#{basename}.json") }
  let(:other_source) { File.join(tmp_root, '242', 'another-meeting-lt4.json') }

  def populator
    described_class.new(source_path:, progress: Import::Progress::Null.new,
                        **(1..4).to_h { |phase| [:"phase#{phase}_path", File.join(work_dir, "#{basename}-phase#{phase}.json")] })
  end

  before(:each) do
    FileUtils.cp(fixtures_dir.join("#{basename}.json"), work_dir)
    (1..4).each { |phase| FileUtils.cp(fixtures_dir.join("#{basename}-phase#{phase}.json"), work_dir) }
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  it 'stages every source row with a category (parity ok) and keeps the existing phase5 _meta' do
    phase5_path = File.join(work_dir, "#{basename}-phase5.json")
    File.write(phase5_path, JSON.generate('_meta' => { 'individual_result_overwrite' => { 'enabled' => false } }, 'programs' => []))

    stats = populator.populate!

    expect(stats[:collisions]).to be_empty
    expect(stats[:parity]).to include('mismatched_programs' => [])
    expect(stats[:parity]['staged']).to eq(stats[:parity]['expected'])
    payload = JSON.parse(File.read(phase5_path))
    expect(payload['_meta']).to eq('individual_result_overwrite' => { 'enabled' => false })
    expect(payload['programs']).not_to be_empty
    expect(payload).not_to have_key('data')
  end

  it 'reports a key already staged by another source, without reusing its row' do
    populator.populate!
    taken = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).order(:id).first
    taken.update_column(:phase_file_path, other_source) # rubocop:disable Rails/SkipsModelValidations

    stats = populator.populate!

    expect(stats[:collisions]).to contain_exactly(include(import_key: taken.import_key, other_source:))
    expect(taken.reload.phase_file_path).to eq(other_source)
    expect(GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path, import_key: taken.import_key)).to be_empty
    expect(stats[:parity]['mismatched_programs'].size).to eq(1)
    expect(stats[:parity]['staged']).to eq(stats[:parity]['expected'] - 1)
  end

  it 'leaves the previous staging rows in place when the repopulate fails' do
    populator.populate!
    count = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).count
    failing = populator
    allow(failing).to receive(:populate_lt4_relay_results!).and_raise(ActiveRecord::StatementInvalid, 'deadlock')

    expect { failing.populate! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).count).to eq(count)
  end
end
