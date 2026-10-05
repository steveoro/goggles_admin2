# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::StructureValidator do
  let(:season) { FactoryBot.create(:season) }
  let(:city) { FactoryBot.create(:city) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool, city: city) }

  let(:valid_session_hash) do
    {
      'id' => nil,
      'description' => 'Session 1, 2026-10-24',
      'session_order' => 1,
      'scheduled_date' => '2026-10-24',
      'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
      'swimming_pool' => {
        'id' => swimming_pool.id,
        'name' => swimming_pool.name,
        'nick_name' => swimming_pool.nick_name,
        'address' => swimming_pool.address,
        'pool_type_id' => swimming_pool.pool_type_id,
        'lanes_number' => swimming_pool.lanes_number,
        'city_id' => city.id,
        'city' => {
          'id' => city.id,
          'name' => city.name,
          'area' => city.area,
          'zip' => city.zip,
          'country' => city.country,
          'country_code' => city.country_code
        }
      }
    }
  end

  let(:valid_phase1_data) do
    {
      'season_id' => season.id,
      'name' => 'Test Meeting',
      'code' => 'testmeeting',
      'header_year' => '2026/2027',
      'header_date' => '2026-10-24',
      'edition' => 1,
      'edition_type_id' => GogglesDb::EditionType::ORDINAL_ID,
      'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID,
      'dateYear1' => 2026,
      'dateMonth1' => 10,
      'dateDay1' => 24,
      'meeting_session' => [valid_session_hash]
    }
  end

  describe '#valid?' do
    it 'is valid for a complete meeting + session + pool/city structure' do
      validator = described_class.new(phase1_data: valid_phase1_data)
      expect(validator).to be_valid
      expect(validator.error_messages).to be_empty
    end

    it 'is valid for a session without a swimming_pool (pool is optional)' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'][0].delete('swimming_pool')
      validator = described_class.new(phase1_data: data)
      expect(validator).to be_valid
    end

    it 'is invalid when the meeting code is missing' do
      data = valid_phase1_data.deep_dup
      data['code'] = nil
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.meeting_errors['code']).to be_present
      expect(validator.error_messages.join).to match(/code/i)
    end

    it 'is invalid when header_year or edition are missing' do
      data = valid_phase1_data.deep_dup
      data['header_year'] = nil
      data['edition'] = nil
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.meeting_errors['header_year']).to be_present
      expect(validator.meeting_errors['edition']).to be_present
    end

    it 'is invalid when the season does not exist' do
      data = valid_phase1_data.deep_dup
      data['season_id'] = -1
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.meeting_errors['season']).to be_present
    end

    it 'is invalid when there are no sessions' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'] = []
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.error_messages.join).to match(/session/i)
    end

    it 'is invalid when a session is missing scheduled_date' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'][0]['scheduled_date'] = nil
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.session_errors[0]['fields']['scheduled_date']).to be_present
    end

    it 'tolerates a missing session_order (defaults to index + 1, like the commit path)' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'][0]['session_order'] = nil
      validator = described_class.new(phase1_data: data)
      expect(validator).to be_valid
      expect(validator.session_errors[0]['fields']).to be_empty
    end

    it 'is invalid when the pool misses required fields (nick_name/lanes_number)' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'][0]['swimming_pool'] = {
        'id' => nil, 'name' => 'New Pool', 'nick_name' => nil, 'lanes_number' => nil,
        'pool_type_id' => GogglesDb::PoolType::MT_50_ID,
        'city_id' => city.id,
        'city' => { 'id' => city.id, 'name' => city.name, 'country_code' => city.country_code }
      }
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      pool_errors = validator.session_errors[0]['swimming_pool']
      expect(pool_errors['nick_name']).to be_present
      expect(pool_errors['lanes_number']).to be_present
    end

    it 'is invalid when a new pool lacks a resolvable city' do
      data = valid_phase1_data.deep_dup
      pool = data['meeting_session'][0]['swimming_pool']
      pool['id'] = nil
      pool['city_id'] = nil
      pool['city'] = {}
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      expect(validator.session_errors[0]['swimming_pool']).to be_present
    end

    it 'is invalid when a new city misses its required fields' do
      data = valid_phase1_data.deep_dup
      data['meeting_session'][0]['swimming_pool']['city'] = {
        'id' => nil, 'name' => nil, 'country_code' => nil
      }
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      city_errors = validator.session_errors[0]['city']
      expect(city_errors['name']).to be_present
    end

    it 'reports calendar-level errors on meeting fields when header_date is missing' do
      data = valid_phase1_data.deep_dup
      data['header_date'] = nil
      validator = described_class.new(phase1_data: data)
      expect(validator).not_to be_valid
      # scheduled_date -> header_date mapping
      expect(validator.meeting_errors['header_date']).to be_present
    end
  end

  describe 'existing rows' do
    let(:meeting) { FactoryBot.create(:meeting, season: season) }
    let(:meeting_session) { FactoryBot.create(:meeting_session, meeting: meeting, swimming_pool: swimming_pool) }

    it 'is valid when pointing at an existing meeting and session' do
      data = valid_phase1_data.deep_dup
      data['id'] = meeting.id
      data['code'] = meeting.code
      data['edition'] = meeting.edition
      data['meeting_session'][0]['id'] = meeting_session.id
      validator = described_class.new(phase1_data: data)
      expect(validator).to be_valid
    end

    it 'treats a stale session id as a new draft (still field-validated)' do
      data = valid_phase1_data.deep_dup
      data['id'] = meeting.id
      data['code'] = meeting.code
      data['meeting_session'][0]['id'] = -1
      validator = described_class.new(phase1_data: data)
      # A nonexistent id drops out of the new draft, so fields still validate
      # and the structure remains valid overall.
      expect(validator).to be_valid
      expect(validator.session_errors[0]['fields']).to be_empty
    end
  end
end
