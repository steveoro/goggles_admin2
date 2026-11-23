# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::RemoteWrite do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_url) { 'http://localhost:8081' }

  after(:each) { Current.reset }

  it 'is valid with the factory defaults and requires method, endpoint and base URL' do
    expect(FactoryBot.build(:ops_remote_write)).to be_valid
    %i[http_method endpoint base_url].each do |attr|
      expect(FactoryBot.build(:ops_remote_write, attr => nil)).not_to be_valid
    end
  end

  describe '.record!' do
    let(:result) { DummyResponse.new(body: 'true') }

    it 'stores the call outcome, the payload keys and the Current source & user' do
      Current.source = 'stats#update'
      Current.user_id = 7
      row = described_class.record!(http_method: :PUT, endpoint: 'api_daily_use/3', base_url: "#{api_url}/",
                                    payload_keys: [:route, 'count'], result:)
      expect(row.reload).to have_attributes(http_method: 'put', endpoint: 'api_daily_use/3', base_url: api_url,
                                            status_code: 200, unreachable: false, error_detail: nil,
                                            payload_keys: %w[route count], source: 'stats#update', user_id: 7)
      expect(row.created_at).to be_present
    end

    it 'stores the error detail of a failed call' do
      failed = APIProxy::Result.new(instance_double(RestClient::Response, code: 500, body: 'boom', headers: {}))
      row = described_class.record!(http_method: 'post', endpoint: 'team', base_url: api_url, result: failed)
      expect(row).to have_attributes(status_code: 500, error_detail: 'boom', status: 'failed')
    end
  end

  describe 'scopes' do
    let!(:done) { FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'meeting/1') }
    let!(:failed) { FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'team/2', status_code: 422) }
    let!(:unreachable) do
      FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'team/3', status_code: 503, unreachable: true)
    end
    let!(:elsewhere) { FactoryBot.create(:ops_remote_write, base_url: 'http://other:8081', endpoint: 'user/4') }

    it 'filters by outcome' do
      expect(described_class.with_status('success')).to contain_exactly(done, elsewhere)
      expect(described_class.with_status('failed')).to contain_exactly(failed)
      expect(described_class.with_status('unreachable')).to contain_exactly(unreachable)
      expect(described_class.with_status('')).to contain_exactly(done, failed, unreachable, elsewhere)
      expect([done, failed, unreachable].map(&:status)).to eq(%w[success failed unreachable])
    end

    it 'filters by endpoint text and base URL, newest first' do
      expect(described_class.endpoint_like('team')).to contain_exactly(failed, unreachable)
      expect(described_class.endpoint_like('%')).to be_empty
      expect(described_class.for_base_url("#{api_url}/").recent).to eq([unreachable, failed, done])
    end

    it 'counts as unacknowledged only the successful writes to that API after the last acknowledgement' do
      expect(described_class.unacknowledged(api_url)).to contain_exactly(done)
      travel(1.second) { described_class.acknowledge! }
      expect(described_class.unacknowledged(api_url)).to be_empty
      later = travel(2.seconds) { FactoryBot.create(:ops_remote_write, base_url: api_url) }
      expect(described_class.unacknowledged(api_url)).to contain_exactly(later)
    end
  end

  describe '.acknowledge! / .acknowledged_at' do
    it 'stores the time in the drift.acknowledged_at setting' do
      expect(described_class.acknowledged_at).to be_nil
      time = Time.zone.parse('2026-11-23 10:15:30.123456')
      described_class.acknowledge!(time)
      expect(Ops::Setting.fetch('drift.acknowledged_at')).to eq('2026-11-23T10:15:30.123456Z')
      expect(described_class.acknowledged_at).to eq(time)
    end
  end
end
