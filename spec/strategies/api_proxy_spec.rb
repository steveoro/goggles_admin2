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
          expect(result_hash.count).to eq(50) # hard-coded limit set in support/webmocks.rb
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

  describe 'Result' do
    let(:fake_response) do
      double(code: response_code, body: response_body, headers: response_headers)
    end
    let(:response_code) { 200 }
    let(:response_headers) { {} }
    subject { APIProxy::Result.new(fake_response) }

    context 'with a JSON object body,' do
      let(:response_body) { { 'id' => 7, 'name' => 'test' }.to_json }

      it 'returns the body as a valid JSON string' do
        expect(JSON.parse(subject.body)).to eq('id' => 7, 'name' => 'test')
      end
      it 'exposes the parsed body through #json' do
        expect(subject.json['id']).to eq(7)
      end
      it 'delegates code & headers' do
        expect(subject.code).to eq(200)
        expect(subject.headers).to eq({})
      end
    end

    context 'with a JSON primitive body,' do
      let(:response_body) { 'true' }

      it 'keeps the primitive body as-is' do
        expect(subject.body).to eq('true')
      end
      it 'exposes the primitive through #json' do
        expect(subject.json).to be(true)
      end
    end

    context 'with a non-JSON error body,' do
      let(:response_code) { 503 }
      let(:response_body) { 'Service Unavailable' }

      it 'normalizes the body into an error JSON' do
        expect(JSON.parse(subject.body)).to eq('error' => 'Service Unavailable')
      end
      it 'exposes the body text as #error_detail' do
        expect(subject.error_detail).to eq('Service Unavailable')
      end
    end

    context 'with a blank body,' do
      let(:response_code) { 500 }
      let(:response_body) { '' }

      it 'normalizes the body into an error JSON with the status code' do
        expect(JSON.parse(subject.body)).to eq('error' => 'Error 500')
      end
      it 'falls back to the status code for #error_detail' do
        expect(subject.error_detail).to eq('Error 500')
      end
    end

    context 'with a blank body on a successful response,' do
      let(:response_body) { '' }

      it 'normalizes the body into an empty JSON object (no content)' do
        expect(JSON.parse(subject.body)).to eq({})
        expect(subject.json).to eq({})
      end
    end

    context 'with an X-Error-Detail header,' do
      let(:response_code) { 422 }
      let(:response_body) { { error: 'generic' }.to_json }
      let(:response_headers) { { x_error_detail: 'the real reason' } }

      it 'prefers the header for #error_detail' do
        expect(subject.error_detail).to eq('the real reason')
      end
    end
  end
  #-- -----------------------------------------------------------------------
  #++
end
