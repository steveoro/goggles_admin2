# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::Verdicts::Phase1 do
  let(:tmp_dir) { Dir.mktmpdir('verdict1-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: tmp_dir) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def verdict = described_class.new(pipeline.reload!).call
  def codes = verdict.issues.pluck('code')

  it 'is clean for a valid meeting matched by FIN event id' do
    stub_valid_structure
    expect(verdict).to be_clean
    expect(verdict.counts).to include('matched_by' => 'fin_event_id', 'sessions' => 1)
  end

  it 'is blocked by an invalid structure, a crawl retry or a FIN id linked to another meeting' do
    allow(Import::StructureValidator).to receive(:new)
      .and_return(instance_double(Import::StructureValidator, valid?: false, error_messages: ['Code missing']))
    allow(pipeline).to receive(:retry_needed?).and_return(true)
    calendar = FactoryBot.create(:calendar, season_id: 242)
    calendar.update_columns(results_code: '990001', meeting_id: 1) # rubocop:disable Rails/SkipsModelValidations

    expect(verdict).to be_blocked
    expect(codes).to contain_exactly('structure_invalid', 'retry_needed', 'fin_link_conflict')
  end

  it 'asks for a review of extraction warnings and new sessions in an existing meeting until Step 1 is saved' do
    stub_valid_structure
    File.write(pipeline.source_path, JSON.generate(JSON.parse(File.read(pipeline.source_path)).merge('_meta' => { 'warnings' => ['odd date'] })))
    data = pipeline.phase_data(1)
    data['meeting_session'] << { 'id' => nil, 'session_order' => 2 }
    PhaseFileManager.new(pipeline.phase_path(1)).write!(data:, meta: pipeline.phase_meta(1))
    pipeline.send(:stamp_built!, 1)
    fresh = DataFix::Pipeline.for(pipeline.source_path, progress: Import::Progress::Null.new)
    expect(described_class.new(fresh).call.issues.pluck('code')).to contain_exactly('source_warnings', 'new_session_in_existing_meeting')

    fresh.mark_edited!(1, action: 'update_phase1_meeting')
    expect(described_class.new(fresh.reload!).call).to be_clean
  end
end
