# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrawlerClient do
  subject(:client) { described_class.new }

  let(:base_url) { PullController::CRAWLER_API_URL }
  let(:meeting_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html' }

  describe '#status' do
    it 'returns the parsed status Hash' do
      body = { 'timestamp' => '20261109-184157', 'status' => 'OK, done, idle', 'detail' => 'Done.' }
      stub_request(:get, "#{base_url}status").to_return(status: 200, body: body.to_json)
      expect(client.status).to eq(body)
    end

    it 'returns nil when the connection is refused' do
      stub_request(:get, "#{base_url}status").to_raise(Errno::ECONNREFUSED)
      expect(client.status).to be_nil
    end

    it 'returns nil on timeouts' do
      stub_request(:get, "#{base_url}status").to_timeout
      expect(client.status).to be_nil
    end

    it 'returns nil on a non-JSON body' do
      stub_request(:get, "#{base_url}status").to_return(status: 200, body: 'garbage')
      expect(client.status).to be_nil
    end
  end

  describe '#pull_meeting' do
    it 'calls /pull_results in direct single-meeting mode (layout 2)' do
      request = stub_request(:get, "#{base_url}pull_results")
                .with(query: { 'season_id' => '262', 'layout' => '2', 'meeting_url' => meeting_url })
                .to_return(status: 200, body: { status: 'OK, idle' }.to_json)
      result = client.pull_meeting(season_id: 262, url: meeting_url)
      expect(request).to have_been_requested
      expect(result).to be_ok
      expect(result.body).to eq('status' => 'OK, idle')
    end

    it 'returns a failed Result with the API error on a 400' do
      stub_request(:get, /pull_results/).to_return(status: 400, body: { error: 'Missing season_id' }.to_json)
      result = client.pull_meeting(season_id: 262, url: meeting_url)
      expect(result).not_to be_ok
      expect(result.code).to eq(400)
      expect(result.error).to include('Missing season_id')
      expect(result).not_to be_unreachable
    end

    [Errno::ECONNREFUSED, SocketError, Errno::EHOSTUNREACH].each do |error_class|
      it "returns an unreachable Result on #{error_class}" do
        stub_request(:get, /pull_results/).to_raise(error_class)
        result = client.pull_meeting(season_id: 262, url: meeting_url)
        expect(result).not_to be_ok
        expect(result).to be_unreachable
        expect(result.error).to include(error_class.name)
      end
    end

    it 'returns an unreachable Result on timeouts' do
      stub_request(:get, /pull_results/).to_timeout
      expect(client.pull_meeting(season_id: 262, url: meeting_url)).to be_unreachable
    end
  end

  describe CrawlerClient::Status do
    let(:now) { Time.utc(2026, 11, 12, 10, 0, 0) }

    def status_for(label, timestamp = '20261112-095500')
      described_class.from('status' => label, 'timestamp' => timestamp, 'detail' => 'x')
    end

    it 'parses the UTC timestamp written by the crawler' do
      expect(status_for('OK, running').timestamp).to eq(Time.utc(2026, 11, 12, 9, 55, 0))
    end

    it 'is nil for a non-Hash' do
      expect(described_class.from(nil)).to be_nil
    end

    ['OK, idle', 'OK, done, idle', 'DONE', 'ERROR', 'no-file'].each do |label|
      it "treats '#{label}' as idle" do
        expect(status_for(label)).to be_idle
        expect(status_for(label).busy?(now:, stale_after: 30.minutes)).to be false
      end
    end

    ['OK, running', 'OK, processing 1/1', 'OK, postprocessing'].each do |label|
      it "treats a fresh '#{label}' as busy" do
        expect(status_for(label).busy?(now:, stale_after: 30.minutes)).to be true
      end
    end

    it 'treats an old running status (or one without timestamp) as stale, not busy' do
      old = status_for('OK, running', '20261112-080000')
      expect(old.stale?(now:, stale_after: 30.minutes)).to be true
      expect(old.busy?(now:, stale_after: 30.minutes)).to be false
      expect(status_for('OK, running', nil).busy?(now:, stale_after: 30.minutes)).to be false
    end

    it 'detects errors' do
      expect(status_for('ERROR')).to be_error
      expect(status_for('OK, done, idle')).not_to be_error
    end
  end
end
