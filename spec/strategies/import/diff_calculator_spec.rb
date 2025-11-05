# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::DiffCalculator do
  describe '.compute' do
    context 'with a new model row (no ID)' do
      it 'returns all non-nil attributes except excluded columns' do
        team = FactoryBot.build(:team, name: 'Test Team', city: FactoryBot.create(:city))

        diff = described_class.compute(team)

        expect(diff).to include('name' => 'Test Team')
        expect(diff).not_to have_key('lock_version')
        expect(diff).not_to have_key('created_at')
        expect(diff).not_to have_key('updated_at')
      end

      it 'excludes nil values' do
        team = FactoryBot.build(:team, name: 'Test Team', notes: nil)

        diff = described_class.compute(team)

        expect(diff).not_to have_key('notes')
      end
    end

    context 'with an existing model row (with ID)' do
      let(:team) { FactoryBot.create(:team, name: 'Original Name', notes: 'Original notes') }

      it 'returns only changed attributes' do
        team.name = 'Updated Name'

        diff = described_class.compute(team)

        expect(diff).to eq({ 'name' => 'Updated Name' })
      end

      it 'excludes unchanged attributes' do
        team.name = 'Updated Name'

        diff = described_class.compute(team)

        expect(diff).not_to have_key('notes')
        expect(diff).not_to have_key('city_id')
      end

      it 'excludes metadata columns' do
        team.name = 'Updated Name'
        team.updated_at = 1.day.from_now

        diff = described_class.compute(team)

        expect(diff).not_to have_key('id')
        expect(diff).not_to have_key('lock_version')
        expect(diff).not_to have_key('created_at')
        expect(diff).not_to have_key('updated_at')
      end

      it 'returns empty hash when nothing changed' do
        diff = described_class.compute(team)

        expect(diff).to be_empty
      end

      it 'works with explicit db_row parameter' do
        db_team = GogglesDb::Team.find(team.id)
        team.name = 'Updated Name'

        diff = described_class.compute(team, db_team)

        expect(diff).to eq({ 'name' => 'Updated Name' })
      end
    end

    context 'with Calendar model (special case)' do
      let(:season) { GogglesDb::Season.last(300).sample }
      let(:calendar) do
        FactoryBot.create(:calendar, season: season, meeting: FactoryBot.create(:meeting, season: season))
      end

      it 'excludes created_at but not updated_at for Calendars' do
        calendar.meeting_place = 'Updated location'

        diff = described_class.compute(calendar)

        # Calendar should allow updated_at updates
        expect(diff).to include('meeting_place' => 'Updated location')
        expect(diff).not_to have_key('created_at')
      end
    end
  end
end
