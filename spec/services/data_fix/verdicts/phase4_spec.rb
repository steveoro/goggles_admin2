# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::Verdicts::Phase4 do
  let(:tmp_dir) { Dir.mktmpdir('verdict4-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: tmp_dir) }
  let(:event_type) { GogglesDb::EventType.find_by(code: '50SL') }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def verdict_for(sessions)
    PhaseFileManager.new(pipeline.phase_path(4)).write!(data: { 'sessions' => sessions }, meta: {})
    described_class.new(pipeline.reload!).call
  end

  it 'is clean for resolvable events under the Phase 1 sessions' do
    verdict = verdict_for([{ 'session_order' => 1, 'events' => [{ 'key' => '50SL', 'session_order' => 1, 'event_type_id' => event_type.id }] }])
    expect(verdict).to be_clean
    expect(verdict.counts).to include('sessions' => 1, 'events' => 1)
  end

  it 'is blocked by unknown event types, sessions missing from Phase 1 and mismatched session orders' do
    verdict = verdict_for([
                            { 'session_order' => 1, 'events' => [{ 'key' => 'ZZZ99', 'distance' => 9999, 'stroke' => 'XX', 'session_order' => 1 },
                                                                 { 'key' => '50SL', 'session_order' => 3 }] },
                            { 'session_order' => 7, 'events' => [{ 'key' => '100SL', 'session_order' => 7 }] }
                          ])
    expect(verdict).to be_blocked
    expect(verdict.issues.pluck('code')).to contain_exactly('event_type_unresolved', 'session_missing', 'session_order_mismatch')
  end
end
