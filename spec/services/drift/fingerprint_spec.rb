# frozen_string_literal: true

require 'rails_helper'

# Local aggregates run on the test DB (read only); the remote call is always stubbed.
RSpec.describe Drift::Fingerprint do
  let(:api_url) { 'http://localhost:8081' }

  describe '.local' do
    it 'returns COUNT(*), MAX(id) and MAX(updated_at) of every whitelisted table, plus the schema version' do
      result = described_class.local
      expect(result['tables'].keys).to eq(Drift::Tables.all)
      expect(result['errors']).to eq({})
      expect(result['light']).to be false
      expect(result['tables']['laps']).to eq(
        'count' => GogglesDb::Lap.count, 'max_id' => GogglesDb::Lap.maximum(:id),
        'max_updated_at' => GogglesDb::Lap.maximum(:updated_at)&.utc&.iso8601
      )
      expect(result['tables']['meetings']['count']).to eq(GogglesDb::Meeting.count)
      expect(result['schema_version']).to eq(ActiveRecord::Base.connection.select_value('SELECT MAX(version) FROM schema_migrations').to_s)
    end

    it 'reads only MAX(id) in light mode, for the requested tables' do
      result = described_class.local(tables: %w[relay_laps laps nope], light: true)
      expect(result['tables']).to eq('laps' => { 'max_id' => GogglesDb::Lap.maximum(:id) },
                                     'relay_laps' => { 'max_id' => GogglesDb::RelayLap.maximum(:id) })
      expect(result['light']).to be true
    end

    it 'reports a table that cannot be read under errors, never raising' do
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:select_value).and_call_original
      allow(connection).to receive(:select_value).with(/`swimmers`/).and_raise(ActiveRecord::StatementInvalid, 'boom')
      result = described_class.local(tables: %w[swimmers teams], light: true)
      expect(result['tables'].keys).to eq(%w[teams])
      expect(result['errors']['swimmers']).to include('boom')
    end
  end

  describe '.remote' do
    let(:payload) do
      { 'environment' => 'production', 'schema_version' => '20261027120100',
        'import_queue' => { 'next_id' => 9124, 'batch_queued' => 0, 'batch_failed' => 0 },
        'tables' => { 'laps' => { 'count' => 10, 'max_id' => 100, 'max_updated_at' => '2026-11-22T10:00:00Z' } } }
    end

    def answer(body, code: 200, headers: {})
      APIProxy::Result.new(instance_double(RestClient::Response, code:, body: body.to_json, headers:))
    end

    it 'GETs tools/db_fingerprint with the given JWT and returns the payload' do
      allow(APIProxy).to receive(:call).and_return(answer(payload))
      remote = described_class.remote(base_url: api_url, jwt: 'jwt')
      expect(remote).to be_ok
      expect(remote.tables['laps']['max_id']).to eq(100)
      expect(APIProxy).to have_received(:call)
        .with(method: :get, url: 'tools/db_fingerprint', jwt: 'jwt', params: {}, base_url: api_url, open_timeout: 5, timeout: 30)
    end

    it 'asks for a table subset in light mode with shorter timeouts' do
      allow(APIProxy).to receive(:call).and_return(answer(payload))
      described_class.remote(base_url: api_url, jwt: 'jwt', tables: %w[relay_laps laps], light: true)
      expect(APIProxy).to have_received(:call)
        .with(hash_including(params: { tables: 'laps,relay_laps', light: 1 }, open_timeout: 5, timeout: 10))
    end

    it 'makes no call without a JWT' do
      allow(APIProxy).to receive(:call)
      expect(described_class.remote(base_url: api_url, jwt: nil).status).to eq('no_credentials')
      expect(APIProxy).not_to have_received(:call)
    end

    it 'maps the failures to a status' do
      unreachable = APIProxy::Result.new(APIProxy::UnreachableResponse.new(api_url, Errno::ECONNREFUSED.new))
      {
        unreachable => 'unreachable',
        answer({ 'error' => 'Unauthorized' }, code: 401) => 'unauthorized',
        answer({ 'error' => 'Not found' }, code: 404) => 'no_capability',
        answer({ 'error' => 'x' }, code: 422, headers: { x_error_detail: 'Unknown table nope' }) => 'rejected',
        answer(['unexpected']) => 'error'
      }.each do |result, status|
        allow(APIProxy).to receive(:call).and_return(result)
        remote = described_class.remote(base_url: api_url, jwt: 'jwt')
        expect(remote.status).to eq(status)
        expect(remote.payload).to eq({})
      end
    end

    it 'never raises' do
      allow(APIProxy).to receive(:call).and_raise(RuntimeError, 'boom')
      expect(described_class.remote(base_url: api_url, jwt: 'jwt')).to have_attributes(status: 'error', error: 'RuntimeError: boom')
    end
  end
end
