# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::Verdicts::Phase5 do
  let(:tmp_dir) { Dir.mktmpdir('verdict5-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: tmp_dir) }
  let(:clean_preflight) { Import::CommitPreflight::Result.new(errors: [], warnings: []) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def write_phase5(meta: {}, programs: [])
    PhaseFileManager.new(pipeline.phase_path(5)).write_payload!({ '_meta' => meta, 'name' => 'phase5', 'programs' => programs })
    pipeline.reload!
  end

  def stage_row!(import_key: 'verdict5-mir')
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key:, phase_file_path: pipeline.source_path, swimmer_key: 'X|Y|1980')
  end

  before(:each) do
    allow(Import::CommitPreflight).to receive(:new).and_return(instance_double(Import::CommitPreflight, call: clean_preflight))
    allow(DataFix::IssueDetector).to receive(:detect_programs_with_issues).and_return([])
  end

  it 'is blocked when nothing is staged for a result-bearing source' do
    write_phase5
    expect(described_class.new(pipeline).call.issues.pluck('code')).to eq(['nothing_staged'])
  end

  it 'is clean with staged rows and no problem' do
    write_phase5
    stage_row!
    verdict = described_class.new(pipeline.reload!).call
    expect(verdict).to be_clean
    expect(verdict.counts).to include('results' => 1, 'new_results' => 1)
  end

  it 'is blocked by a cross-source collision, naming the other source, and by a parity gap' do
    write_phase5(meta: { 'populate' => { 'collisions_count' => 1, 'collisions' => [{ 'import_key' => 'k', 'other_source' => '/x/262/other-lt4.json' }],
                                         'parity' => { 'mismatched_programs' => ['1-50SL-M45-M: 3/4'] } } })
    stage_row!
    verdict = described_class.new(pipeline.reload!).call
    expect(verdict).to be_blocked
    collision = verdict.issues.find { |issue| issue['code'] == 'collisions' }
    expect(collision).to include('message' => 'other-lt4.json')
    expect(verdict.issues.pluck('code')).to include('parity')
  end

  it 'is blocked by the IssueDetector programs and by preflight errors' do
    write_phase5(programs: [{ 'session_order' => 1 }])
    stage_row!
    allow(DataFix::IssueDetector).to receive(:detect_programs_with_issues).and_return([{}])
    failing = Import::CommitPreflight::Result.new(errors: [{ code: 'existing_team_name', message: 'x', count: 2 }], warnings: [])
    allow(Import::CommitPreflight).to receive(:new).and_return(instance_double(Import::CommitPreflight, call: failing))
    expect(described_class.new(pipeline.reload!).call.issues.pluck('code')).to contain_exactly('result_issues', 'preflight_existing_team_name')
  end

  it 'asks for a review of an overwrite selection and of partial duplicates' do
    write_phase5(meta: { 'individual_result_overwrite' => { 'enabled' => true, 'snapshot' => { 'candidates' => [{ 'id' => 1, 'selected' => true }] } },
                         'populate' => { 'auto_verify' => { 'partial' => ['k1'], 'verified' => 2 } } })
    stage_row!
    verdict = described_class.new(pipeline.reload!).call
    expect(verdict).to be_review
    expect(verdict.issues.pluck('code')).to contain_exactly('overwrite_selected', 'partial_duplicates')
    expect(verdict.counts).to include('overwrite_deletions' => 1, 'auto_verified' => 2)
  end

  it 'is clean for a result-free source once Phase 1 is valid (result_free_manifest)' do
    FileUtils.cp(Rails.root.join('spec/fixtures/data_fix/pipeline/result_free_manifest.json'), pipeline.source_path)
    [2, 3].each { |phase| FileUtils.rm_f(pipeline.phase_path(phase)) } # (a manifest source needs Phase 1 only)
    pipeline.send(:stamp_built!, 1)
    write_phase5
    stub_valid_structure
    expect(described_class.new(pipeline.reload!).call).to be_clean
    summary = pipeline.summary
    expect(summary.result_free).to be true
    expect([2, 3, 4].map { |phase| summary[phase].status }).to all(eq('clean'))
    expect(summary[2].counts).to include('skipped' => true)
  end
end
