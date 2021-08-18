# frozen_string_literal: true

require 'rails_helper'
require 'support/webmock'

RSpec.describe APIProxy, type: :strategy do
  # Given these involve only mocked API endpoints we use this as a simple testbed for
  # verifying the method call and build up the WebMock stubs.
  describe 'self.call' do
    let(:fake_admin_payload) { { 'e' => 'admin-email', 'p' => 'fake-pwd', 't' => 'fake-token' } }
    let(:fake_jwt) { '<A_VALID_JWT>' }

    describe 'POST url with valid parameters,' do
      subject { APIProxy.call(method: :post, url: 'session', payload: fake_admin_payload) }

      it 'has a successful return code' do
        expect(subject.code).to eq(200)
      end
      it 'has a valid JSON body, including the JWT' do
        result_hash = JSON.parse(subject.body)
        expect(result_hash['jwt']).to be_present
      end
    end

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

      # TODO: list of settings
    end

    describe 'PUT url with valid parameters,' do
      # TODO
    end

    describe 'DELETE url with valid parameters,' do
      # TODO
    end
  end
end
