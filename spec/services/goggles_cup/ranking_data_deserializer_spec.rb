# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GogglesCup::RankingDataDeserializer do
  let(:team) { FactoryBot.create(:team) }
  let(:swimmer) { FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980) }
  let(:cup) do
    FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025,
                                   swimmers_ids: swimmer.id.to_s)
  end

  let(:ranking_json) do
    {
      description: 'Test Cup', season_year: 2025, max_points: 1000, team_id: team.id,
      end_date: '2026-07-31', swimmer_ids: [swimmer.id], no_duplicated_events: false,
      data: {
        base_timings: {},
        scores: {
          swimmer.id.to_s => [
            {
              'event_type_code' => '50SL', 'pool_type_code' => '25',
              'total_hundredths' => 3000, 'meeting_date' => '2025-01-15',
              'meeting_name' => 'Test Meeting', 'meeting_id' => 42,
              'meeting_individual_result_id' => 99, 'team_id' => team.id,
              'team_name' => 'TEST TEAM', 'old_total_hundredths' => 3200,
              'old_meeting_date' => '2024-01-10', 'old_meeting_name' => 'Old Meeting',
              'old_meeting_id' => 30, 'old_meeting_individual_result_id' => 88,
              'row_score' => 1066.67
            }
          ]
        }
      }
    }.to_json
  end

  before(:each) do
    cup.update!(ranking_data: ranking_json)
  end

  it 'returns an array of ranking entries with swimmer info' do
    result = described_class.new(cup).call

    expect(result).to be_an(Array)
    expect(result.length).to eq(1)
    entry = result.first
    expect(entry[:swimmer_id]).to eq(swimmer.id)
    expect(entry[:swimmer_name]).to eq('TEST SWIMMER')
    expect(entry[:swimmer_year_of_birth]).to eq(1980)
  end

  it 'wraps score rows in a dot-access wrapper' do
    result = described_class.new(cup).call
    row = result.first[:top_rows].first[:row]

    expect(row).to respond_to(:event_type_code)
    expect(row.event_type_code).to eq('50SL')
    expect(row.total_hundredths).to eq(3000)
    expect(row.meeting_name).to eq('Test Meeting')
  end

  it 'computes overall_score by summing row_scores' do
    result = described_class.new(cup).call

    expect(result.first[:overall_score]).to eq(1066.67)
  end

  it 'sorts entries by overall_score descending' do
    other_swimmer = FactoryBot.create(:swimmer, complete_name: 'OTHER SWIMMER', year_of_birth: 1990)
    cup.update!(swimmers_ids: "#{swimmer.id},#{other_swimmer.id}")
    cup.update!(ranking_data: {
      data: {
        scores: {
          swimmer.id.to_s => [{ 'row_score' => 500.0 }],
          other_swimmer.id.to_s => [{ 'row_score' => 1500.0 }]
        }
      }
    }.to_json)

    result = described_class.new(cup).call

    expect(result.first[:swimmer_id]).to eq(other_swimmer.id)
    expect(result.second[:swimmer_id]).to eq(swimmer.id)
  end

  it 'returns empty array when ranking_data is nil' do
    cup.update!(ranking_data: nil)

    result = described_class.new(cup).call

    expect(result).to eq([])
  end
end
