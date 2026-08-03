# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GogglesCup::RankingDataSerializer do
  let(:team) { FactoryBot.build(:team, id: 1) }
  let(:cup) do
    FactoryBot.build(:goggle_cup, id: 1, team: team, description: 'Test Cup', season_year: 2025,
                                  max_points: 1000, end_date: Date.new(2026, 7, 31), swimmers_ids: '1,2')
  end

  let(:score_row) do
    instance_double(
      GogglesDb::BestSwimmerCurrentVsPreviousResult,
      attributes: {
        'event_type_id' => 19, 'event_type_code' => '50RA', 'pool_type_id' => 1, 'pool_type_code' => '25',
        'season_id' => 252, 'season_header_year' => '2025/2026',
        'meeting_individual_result_id' => 1_371_664,
        'minutes' => 0, 'seconds' => 36, 'hundredths' => 94, 'total_hundredths' => 3694,
        'meeting_id' => 20_063, 'meeting_date' => '2026-02-21', 'meeting_name' => 'Test Meeting',
        'team_id' => 42, 'team_name' => 'TEST TEAM',
        'old_meeting_individual_result_id' => 1_053_037, 'old_meeting_id' => 19_676,
        'old_meeting_date' => '2023-02-19', 'old_meeting_name' => 'Old Meeting',
        'old_total_hundredths' => 3666, 'old_minutes' => 0, 'old_seconds' => 36, 'old_hundredths' => 66
      }
    )
  end

  let(:ranking_data) do
    [
      {
        swimmer_id: 1,
        swimmer_name: 'TEST SWIMMER',
        swimmer_year_of_birth: 1980,
        overall_score: 1001.07,
        top_rows: [{ row: score_row, row_score: 1001.07 }]
      }
    ]
  end

  before(:each) do
    relation = instance_double(ActiveRecord::Relation)
    allow(GogglesDb::GogglesCup3yBaseTimings).to receive(:where).and_return(relation)
    allow(relation).to receive_messages(includes: relation, group_by: {})
  end

  it 'returns a hash with cup metadata and data sections' do
    result = described_class.new(cup: cup, ranking_data: ranking_data, no_duplicated_events: true).call

    expect(result[:description]).to eq('Test Cup')
    expect(result[:season_year]).to eq(2025)
    expect(result[:team_id]).to eq(1)
    expect(result[:end_date]).to eq('2026-07-31')
    expect(result[:swimmer_ids]).to eq([1, 2])
    expect(result[:no_duplicated_events]).to be(true)
    expect(result[:data]).to have_key(:base_timings)
    expect(result[:data]).to have_key(:scores)
  end

  it 'serializes score rows with subset columns and row_score' do
    result = described_class.new(cup: cup, ranking_data: ranking_data, no_duplicated_events: false).call

    scores = result[:data][:scores]
    expect(scores).to have_key('1')
    entry = scores['1'].first
    expect(entry['event_type_code']).to eq('50RA')
    expect(entry['total_hundredths']).to eq(3694)
    expect(entry['old_total_hundredths']).to eq(3666)
    expect(entry['row_score']).to eq(1001.07)
  end

  it 'returns empty base_timings when no GogglesCup3yBaseTimings rows exist' do
    result = described_class.new(cup: cup, ranking_data: ranking_data, no_duplicated_events: false).call

    expect(result[:data][:base_timings]).to eq({})
  end
end
