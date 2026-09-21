# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LookupController do
  describe 'GET /lookup/:domain' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get('/lookup/seasons', params: { description: 'test' })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) { sign_in_admin(prepare_admin_user) }

      it 'returns an empty array for an unsupported domain' do
        get('/lookup/badges', params: { q: 'test' })
        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to eq([])
      end

      it 'returns an empty array for a missing or too-short query' do
        get('/lookup/seasons', params: { description: 'x' })
        expect(response.parsed_body).to eq([])
        get('/lookup/seasons')
        expect(response.parsed_body).to eq([])
      end

      context 'when searching seasons' do
        let!(:fixture_row) { FactoryBot.create(:season) }

        it 'finds a row by description fragment' do
          get('/lookup/seasons', params: { description: fixture_row.description.last(10) })
          ids = response.parsed_body.pluck('id')
          expect(ids).to include(fixture_row.id)
        end

        it 'finds a row by header_year' do
          get('/lookup/seasons', params: { header_year: fixture_row.header_year })
          ids = response.parsed_body.pluck('id')
          expect(ids).to include(fixture_row.id)
        end

        it 'finds a row by numeric ID' do
          get('/lookup/season', params: { q: fixture_row.id.to_s })
          ids = response.parsed_body.pluck('id')
          expect(ids).to include(fixture_row.id)
        end

        it 'serializes only the safe column subset' do
          get('/lookup/seasons', params: { description: fixture_row.description.last(10) })
          row = response.parsed_body.detect { |r| r['id'] == fixture_row.id }
          expect(row.keys).to contain_exactly(
            'id', 'description', 'header_year', 'edition', 'begin_date', 'end_date', 'season_type_id'
          )
        end
      end

      context 'when searching teams' do
        let!(:fixture_row) { FactoryBot.create(:team) }

        it 'finds a row by name fragment' do
          get('/lookup/teams', params: { name: fixture_row.name.last(10) })
          ids = response.parsed_body.pluck('id')
          expect(ids).to include(fixture_row.id)
        end

        it 'includes the associated city name' do
          get('/lookup/teams', params: { name: fixture_row.name.last(10) })
          row = response.parsed_body.detect { |r| r['id'] == fixture_row.id }
          expect(row['city_name']).to eq(fixture_row.city&.name)
        end
      end

      context 'when searching users' do
        let!(:fixture_row) { FactoryBot.create(:user) }

        it 'finds a row by email fragment' do
          get('/lookup/users', params: { email: fixture_row.email })
          ids = response.parsed_body.pluck('id')
          expect(ids).to include(fixture_row.id)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'GET /lookup/:domain/:id' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get('/lookup/team/1')
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) { sign_in_admin(prepare_admin_user) }

      it 'returns the detail row for a supported domain' do
        fixture_row = FactoryBot.create(:team)
        get("/lookup/team/#{fixture_row.id}")
        json = response.parsed_body
        expect(json['id']).to eq(fixture_row.id)
        expect(json['name']).to eq(fixture_row.name)
      end

      it 'responds 404 for a missing row' do
        get('/lookup/team/0')
        expect(response).to have_http_status(:not_found)
      end

      it 'responds 404 for an unsupported domain' do
        get('/lookup/badge/1')
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
