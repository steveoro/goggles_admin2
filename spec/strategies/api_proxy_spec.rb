# frozen_string_literal: true

require 'rails_helper'
require 'support/webmocks'

RSpec.describe APIProxy, type: :strategy do
  # Given these involve only mocked API endpoints we use this as a simple testbed for
  # verifying the method call and build up the WebMock stubs.
  describe 'self.call' do
    let(:fake_admin_payload) { { 'e' => 'admin-email', 'p' => 'fake-pwd', 't' => 'fake-token' } }
    let(:fake_jwt) { '<A_VALID_JWT>' }

    describe 'POST url with valid parameters,' do
      context 'when requesting a new session,' do
        subject { APIProxy.call(method: :post, url: 'session', payload: fake_admin_payload) }

        it 'has a successful return code' do
          expect(subject.code).to eq(200)
        end
        it 'has a valid JSON body, including the JWT' do
          result_hash = JSON.parse(subject.body)
          expect(result_hash['jwt']).to be_present
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    describe 'GET url with valid parameters,' do
      context 'when requesting the whole list of users,' do
        subject { APIProxy.call(method: :get, url: 'users', jwt: fake_jwt) }

        it 'has a successful return code' do
          expect(subject.code).to eq(200)
        end
        it 'has a valid JSON body, returning the array of user details' do
          result_hash = JSON.parse(subject.body)
          expect(result_hash).to be_present
          expect(result_hash.count).to eq(GogglesDb::User.count)
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    describe 'PUT url with valid parameters,' do
      context 'when editing a user,' do
        let(:fixture_row) { FactoryBot.create(:user) }
        let(:new_description) { 'FAKE UPDATE' } # <= expected by WebMock
        let(:new_birthyear) { 1950 + (rand * 50).to_i }
        subject do
          APIProxy.call(
            method: :put,
            url: "user/#{fixture_row.id}",
            jwt: fake_jwt,
            payload: {
              description: new_description,
              year_of_birth: new_birthyear
            }
          )
        end

        it 'has a successful return code' do
          expect(subject.code).to eq(200)
        end
        it 'returns true for success' do
          expect(subject.body).to eq('true')
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    describe 'DELETE url with valid parameters,' do
      context 'when deleting an import_queue,' do
        let(:fixture_row) { FactoryBot.create(:import_queue) }
        subject do
          APIProxy.call(
            method: :delete,
            url: "import_queue/#{fixture_row.id}",
            jwt: fake_jwt
          )
        end

        it 'has a successful return code' do
          expect(subject.code).to eq(200)
        end
        it 'returns true for success' do
          expect(subject.body).to eq('true')
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
