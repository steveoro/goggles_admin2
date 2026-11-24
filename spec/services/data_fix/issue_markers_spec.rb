# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IssueMarkers do
  def verdict(phase, issues)
    DataFix::Verdict.build(phase:, status: 'review', issues:)
  end

  describe '.phase1' do
    let(:data) { { 'id' => 12, 'meeting_session' => [{ 'id' => 3 }, { 'id' => nil }] } }
    let(:report) { instance_double(Import::StructureValidator, meeting_errors: {}, session_errors: { 0 => { 'fields' => { 'description' => ['missing'] } } }) }

    it 'places the verdict issues and the field errors on the meeting and session cards' do
      issues = [{ 'code' => 'meeting_not_fin_matched', 'level' => 'review' }, { 'code' => 'new_session_in_existing_meeting', 'level' => 'review' },
                { 'code' => 'source_warnings', 'level' => 'info' }]
      markers = described_class.phase1(data:, structure_report: report, verdict: verdict(1, issues))
      expect(markers[:meeting]).to eq(['meeting_not_fin_matched'])
      expect(markers[:sessions]).to eq(0 => ['structure_invalid'], 1 => ['new_session_in_existing_meeting'])
    end
  end

  describe '.team / .swimmer' do
    it 'follows DataFix::ReviewRules (a confirmed row needs nothing)' do
      expect(described_class.team({ 'team_id' => nil, 'fuzzy_matches' => [{ 'id' => 1 }] })).to eq('teams_review')
      expect(described_class.team({ 'team_id' => nil, 'fuzzy_matches' => [{ 'id' => 1 }], 'confirmed' => true })).to be_nil
      expect(described_class.swimmer({ 'swimmer_id' => nil, 'fuzzy_matches' => [], 'confirmed' => true })).to be_nil
    end
  end

  describe '.phase4' do
    it 'marks the events named by the verdict issues, aligned with the events' do
      events = [{ 'key' => '100SL', 'id' => 5, '_session_order' => 1 }, { 'key' => 'ZZZ', '_session_order' => 1 },
                { 'key' => '50FA', '_session_order' => 2 }]
      issues = [{ 'code' => 'event_type_unresolved', 'level' => 'blocked', 'details' => ['ZZZ'] },
                { 'code' => 'session_missing', 'level' => 'blocked', 'details' => [2] },
                { 'code' => 'unmatched_events', 'level' => 'review', 'count' => 2 }]
      expect(described_class.phase4(events:, verdict: verdict(4, issues)))
        .to eq([[], %w[event_type_unresolved unmatched_events], %w[session_missing unmatched_events]])
    end
  end
end
