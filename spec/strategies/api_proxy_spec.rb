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
  describe 'self.call with an unreachable API server' do
    let(:base_url) { 'http://unreachable-api.test:8085' }

    {
      'connection refused' => Errno::ECONNREFUSED,
      'unknown host' => SocketError,
      'open timeout' => RestClient::Exceptions::OpenTimeout
    }.each do |label, error_class|
      context "when the connection fails (#{label})" do
        subject { APIProxy.call(method: :get, url: 'users', jwt: 'fake-jwt', base_url:) }

        before(:each) { WebMock.stub_request(:get, "#{base_url}/api/v3/users").to_raise(error_class) }

        it 'does not raise and returns an unreachable result' do
          expect(subject).to be_unreachable
          expect(subject.code).to eq(APIProxy::UnreachableResponse::CODE)
        end

        it 'has a parsable JSON body and an error detail including the base URL' do
          expect(JSON.parse(subject.body)['error']).to include(base_url)
          expect(subject.error_detail).to include(base_url, error_class.name)
        end
      end
    end

    context 'when the request times out after connecting' do
      subject { APIProxy.call(method: :get, url: 'users', base_url:) }

      before(:each) { WebMock.stub_request(:get, "#{base_url}/api/v3/users").to_timeout }

      it 'returns an unreachable result' do
        expect(subject).to be_unreachable
      end
    end
  end

  describe 'self.ping' do
    let(:base_url) { 'http://ping-api.test:8085' }

    it 'calls the public status endpoint of the given server' do
      WebMock.stub_request(:get, "#{base_url}/api/v3/status").to_return(status: 200, body: { msg: 'OK', version: '7' }.to_json)
      result = APIProxy.ping("#{base_url}/")
      expect(result.code).to eq(200)
      expect(result).not_to be_unreachable
      expect(result.json['version']).to eq('7')
    end

    it 'passes the timeouts to #call only when given' do
      allow(APIProxy).to receive(:call)
      APIProxy.ping(base_url)
      APIProxy.ping(base_url, open_timeout: 3, timeout: 5)
      expect(APIProxy).to have_received(:call).with(method: :get, url: 'status', base_url:)
      expect(APIProxy).to have_received(:call).with(method: :get, url: 'status', base_url:, open_timeout: 3, timeout: 5)
    end
  end

  describe 'self.call timeouts' do
    let(:base_url) { 'http://timeouts-api.test:8085' }

    before(:each) do
      WebMock.stub_request(:get, "#{base_url}/api/v3/users").to_return(status: 200, body: '[]')
      allow(RestClient::Request).to receive(:execute).and_call_original
    end

    it 'uses the default open timeout and no read timeout when none is given' do
      APIProxy.call(method: :get, url: 'users', base_url:)
      expect(RestClient::Request).to have_received(:execute).with(hash_including(open_timeout: APIProxy::OPEN_TIMEOUT))
      expect(RestClient::Request).not_to have_received(:execute).with(hash_including(:timeout))
    end

    it 'passes the given open and read timeouts to RestClient' do
      APIProxy.call(method: :get, url: 'users', base_url:, open_timeout: 2, timeout: 4)
      expect(RestClient::Request).to have_received(:execute).with(hash_including(open_timeout: 2, timeout: 4))
    end
  end

  describe 'remote-write log (Ops::RemoteWrite)' do
    let(:base_url) { 'http://remote-writes-api.test:8085' }
    let(:payload) { { description: 'SECRET-VALUE', year_of_birth: 1970 } }

    before(:each) do
      WebMock.stub_request(:any, %r{\A#{Regexp.escape(base_url)}/api/v3/}).to_return(status: 200, body: 'true')
    end

    after(:each) do
      Current.reset
      Ops::Database.reset_state!
    end

    %i[put post delete].each do |http_method|
      it "logs a #{http_method.upcase} call, with the payload keys only" do
        Current.source = 'api_users#update'
        Current.user_id = 42
        expect { APIProxy.call(method: http_method, url: 'user/12', jwt: 'secret-jwt', payload:, base_url: "#{base_url}/") }
          .to change(Ops::RemoteWrite, :count).by(1)
        row = Ops::RemoteWrite.last
        expect(row).to have_attributes(http_method: http_method.to_s, endpoint: 'user/12', base_url:, status_code: 200,
                                       unreachable: false, error_detail: nil, payload_keys: %w[description year_of_birth],
                                       source: 'api_users#update', user_id: 42)
        expect(row.attributes.to_json).not_to include('SECRET-VALUE', '1970', 'secret-jwt')
      end
    end

    it 'does not log GET calls, the sign-in or the SQL batch push' do
      expect do
        APIProxy.call(method: :get, url: 'users', jwt: 'x', base_url:)
        APIProxy.call(method: :post, url: 'session', payload: { e: 'a', p: 'b' }, base_url:)
        APIProxy.call(method: :post, url: 'import_queue/batch_sql', jwt: 'x', payload: { data: 'SQL' }, base_url:)
      end.not_to change(Ops::RemoteWrite, :count)
    end

    it 'logs a failed call with its error detail (truncated to 300 chars)' do
      WebMock.stub_request(:put, "#{base_url}/api/v3/team/7")
             .to_return(status: 422, body: { error: 'x' * 400 }.to_json)
      result = APIProxy.call(method: :put, url: 'team/7', jwt: 'x', payload: { name: 'A' }, base_url:)
      expect(result.code).to eq(422)
      row = Ops::RemoteWrite.last
      expect(row).to have_attributes(status_code: 422, unreachable: false, status: 'failed')
      expect(row.error_detail.size).to eq(300)
    end

    it 'logs an unreachable server' do
      WebMock.stub_request(:delete, "#{base_url}/api/v3/badge/3").to_raise(Errno::ECONNREFUSED)
      APIProxy.call(method: :delete, url: 'badge/3', jwt: 'x', base_url:)
      expect(Ops::RemoteWrite.last).to have_attributes(status_code: 503, unreachable: true, status: 'unreachable')
      expect(Ops::RemoteWrite.last.error_detail).to include('API unreachable')
    end

    it 'returns the same Result, unchanged, when the ops DB raises' do
      allow(Ops::RemoteWrite).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, 'disk I/O error')
      result = APIProxy.call(method: :put, url: 'user/12', jwt: 'x', payload:, base_url:)
      expect(result).to be_a(APIProxy::Result)
      expect(result.code).to eq(200)
      expect(result.body).to eq('true')
    end

    it 'logs nothing and still returns the Result with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      allow(Ops::RemoteWrite).to receive(:record!)
      result = APIProxy.call(method: :put, url: 'user/12', jwt: 'x', payload:, base_url:)
      expect(result.body).to eq('true')
      expect(Ops::RemoteWrite).not_to have_received(:record!)
    end
  end
end
