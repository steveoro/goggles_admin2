# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::CategoryRecomputer do
  let(:season) { instance_double(GogglesDb::Season, id: 242) }
  let(:categories_cache) { instance_double(PdfResults::CategoriesCache) }
  let(:temp_dir) { Dir.mktmpdir }
  let(:source_path) { File.join(temp_dir, 'meeting-l4.json') }
  let(:progress) { [] }

  after(:each) do
    FileUtils.rm_rf(temp_dir)
  end

  def write_source(payload)
    File.write(source_path, JSON.pretty_generate(payload))
  end

  it 'recomputes swimmer, individual and relay result categories and preserves a numbered backup' do
    write_source(recompute_payload)
    allow(Import::CategoryComputer).to receive_messages(compute_category: [70, 'M70'], compute_relay_category: [1772, '80-99'])

    result = described_class.new(
      source_path: source_path,
      season: season,
      meeting_date: '2025-06-24',
      categories_cache: categories_cache,
      progress: ->(message, current, total) { progress << [message, current, total] }
    ).call

    updated = JSON.parse(File.read(source_path))
    backup = JSON.parse(File.read(File.join(temp_dir, 'meeting-l4.orig.json')))

    expect(updated['swimmers'].first['category']).to eq('M70')
    expect(updated['events'].first['results'].first['category']).to eq('M70')
    expect(updated['events'].last['results'].first['category']).to eq('80-99')
    expect(backup['swimmers'].first['category']).to eq('M65')
    expect(result[:swimmer_categories_changed]).to eq(1)
    expect(result[:result_categories_changed]).to eq(2) # individual + relay
    expect(progress).to eq([['Recomputing swimmer categories', 1, 1]])
  end

  def recompute_payload
    {
      'layoutType' => 4,
      'swimmers' => [
        {
          'key' => 'F|DOE|JANE|1956|TEAM',
          'last_name' => 'DOE',
          'first_name' => 'JANE',
          'year_of_birth' => 1956,
          'gender_type_code' => 'F',
          'category' => 'M65'
        }
      ],
      'events' => [
        { 'relay' => false, 'results' => [{ 'swimmer' => 'F|DOE|JANE|1956|TEAM', 'category' => 'M65' }] },
        { 'relay' => true, 'results' => [{
          'relay' => true, 'category' => 'M60', 'laps' => [
            { 'distance' => '50m', 'swimmer' => 'F|DOE|JANE|1956|TEAM' },
            { 'distance' => '100m', 'swimmer' => 'M|ROSSI|MARIO|1950|TEAM' },
            { 'distance' => '150m', 'swimmer' => 'F|SMITH|ANN|1955|TEAM' },
            { 'distance' => '200m', 'swimmer' => 'M|BROWN|BOB|1960|TEAM' }
          ]
        }] }
      ]
    }
  end

  it 'accepts a non-empty LT4 swimmer dictionary' do
    write_source(
      'layoutType' => 4,
      'swimmers' => {
        'F|DOE|JANE|1956|TEAM' => {
          'lastName' => 'DOE', 'firstName' => 'JANE', 'gender' => 'F', 'year' => '1956', 'category' => 'M65'
        }
      }
    )
    allow(Import::CategoryComputer).to receive(:compute_category).and_return([70, 'M70'])

    result = described_class.new(
      source_path: source_path,
      season: season,
      meeting_date: '2025-06-24',
      categories_cache: categories_cache
    ).call

    expect(JSON.parse(File.read(source_path)).dig('swimmers', 'F|DOE|JANE|1956|TEAM', 'category')).to eq('M70')
    expect(result[:swimmers_processed]).to eq(1)
  end

  it 'recomputes relay category using swimmer index fallback when lap key lacks YOB' do
    write_source(
      'layoutType' => 4,
      'swimmers' => [
        {
          'key' => '|SALA|LUCA|2003|TEAM',
          'last_name' => 'SALA',
          'first_name' => 'LUCA',
          'year_of_birth' => 2003,
          'gender_type_code' => 'M',
          'category' => 'M25'
        }
      ],
      'events' => [
        { 'relay' => true, 'results' => [{
          'relay' => true, 'category' => 'M60', 'laps' => [
            { 'distance' => '50m', 'swimmer' => 'F|MARGIOTTA|ALICE|2004|TEAM' },
            { 'distance' => '100m', 'swimmer' => '|SALA|LUCA||TEAM' },
            { 'distance' => '150m', 'swimmer' => 'M|SEMPRINI|TOMMASO|2003|TEAM' },
            { 'distance' => '200m', 'swimmer' => 'F|CAMPORINI|ELISA|2004|TEAM' }
          ]
        }] }
      ]
    )
    allow(Import::CategoryComputer).to receive_messages(compute_category: [70, 'M70'], compute_relay_category: [1772, '80-99'])

    result = described_class.new(
      source_path: source_path,
      season: season,
      meeting_date: '2026-06-29',
      categories_cache: categories_cache
    ).call

    updated = JSON.parse(File.read(source_path))
    expect(updated['events'].first['results'].first['category']).to eq('80-99')
    expect(result[:result_categories_changed]).to eq(1)
    expect(result[:skipped_categories]).to be_empty
  end

  it 'skips relay result recomputation when YOB cannot be resolved from lap key or swimmer index' do
    write_source(
      'layoutType' => 4,
      'swimmers' => [
        {
          'key' => 'F|DOE|JANE|1956|TEAM',
          'last_name' => 'DOE',
          'first_name' => 'JANE',
          'year_of_birth' => 1956,
          'gender_type_code' => 'F',
          'category' => 'M65'
        }
      ],
      'events' => [
        { 'relay' => true, 'results' => [{
          'relay' => true, 'category' => 'M60', 'laps' => [
            { 'distance' => '50m', 'swimmer' => 'F|UNKNOWN|PERSON||TEAM' },
            { 'distance' => '100m', 'swimmer' => '|MISSING|YOB||TEAM' },
            { 'distance' => '150m', 'swimmer' => 'M|SEMPRINI|TOMMASO|2003|TEAM' },
            { 'distance' => '200m', 'swimmer' => 'F|CAMPORINI|ELISA|2004|TEAM' }
          ]
        }] }
      ]
    )
    allow(Import::CategoryComputer).to receive(:compute_category).and_return([70, 'M70'])

    result = described_class.new(
      source_path: source_path,
      season: season,
      meeting_date: '2026-06-29',
      categories_cache: categories_cache
    ).call

    updated = JSON.parse(File.read(source_path))
    expect(updated['events'].first['results'].first['category']).to eq('M60')
    expect(result[:result_categories_changed]).to eq(0)
    expect(result[:skipped_categories].size).to eq(1)
    expect(result[:skipped_categories].first[:reason]).to eq('unresolved_swimmer_yob')
  end

  it 'rejects a missing or empty swimmers array before creating a backup' do
    write_source('layoutType' => 4, 'events' => [])

    expect do
      described_class.new(
        source_path: source_path,
        season: season,
        meeting_date: '2025-06-24',
        categories_cache: categories_cache
      ).call
    end.to raise_error(described_class::InvalidSource)

    expect(File.exist?(File.join(temp_dir, 'meeting-l4.orig.json'))).to be false
    expect(JSON.parse(File.read(source_path))).not_to have_key('orig')
  end
end
