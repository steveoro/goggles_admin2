# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrawlerClient do
  subject(:client) { described_class.new }

  let(:base_url) { described_class::BASE_URL }
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

  it 'points to the local crawler server (the launcher checks the same server)' do
    expect(base_url).to eq('http://localhost:7000/')
    expect(CrawlerLauncher::STATUS_URL).to eq("#{base_url}status")
  end

  # (phase 15: the commands of the Sources crawler tab, ported from the Pull page calls)
  describe 'the source crawl commands' do
    let(:ok_body) { { status: 'OK, idle' }.to_json }

    it '#pull_calendar calls /pull_calendar with the sub-menu item and the season text' do
      request = stub_request(:get, "#{base_url}pull_calendar")
                .with(query: { 'season_id' => '262', 'start_url' => 'https://www.federnuoto.it/home/master.html',
                               'sub_menu_type' => 'Riepilogo Eventi', 'year_text' => '2025/2026' })
                .to_return(status: 200, body: ok_body)
      result = client.pull_calendar(season_id: 262, start_url: 'https://www.federnuoto.it/home/master.html',
                                    sub_menu_type: 'Riepilogo Eventi', year_text: '2025/2026')
      expect(request).to have_been_requested
      expect(result).to be_ok
    end

    it '#pull_results_from_file calls /pull_results with the calendar CSV path and the layout' do
      request = stub_request(:get, "#{base_url}pull_results")
                .with(query: { 'season_id' => '262', 'file_path' => '/data/calendar.new/262/cal.csv', 'layout' => '2' })
                .to_return(status: 200, body: ok_body)
      expect(client.pull_results_from_file(season_id: 262, file_path: '/data/calendar.new/262/cal.csv', layout: 2)).to be_ok
      expect(request).to have_been_requested
    end

    it '#pull_microplus calls /pull_results_microplus, with the target event only when given' do
      url = 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php'
      plain = stub_request(:get, "#{base_url}pull_results_microplus")
              .with(query: { 'season_id' => '252', 'layout' => '4', 'meeting_url' => url }).to_return(status: 200, body: ok_body)
      filtered = stub_request(:get, "#{base_url}pull_results_microplus")
                 .with(query: { 'season_id' => '252', 'layout' => '4', 'meeting_url' => url, 'target_event' => '200 Misti' })
                 .to_return(status: 200, body: ok_body)
      client.pull_microplus(season_id: 252, url:)
      client.pull_microplus(season_id: 252, url:, target_event: '200 Misti')
      expect(plain).to have_been_requested.once
      expect(filtered).to have_been_requested.once
    end

    it '#pull_ficr and #pull_goandswim call their dedicated endpoints' do
      ficr = stub_request(:get, "#{base_url}pull_results_ficr")
             .with(query: hash_including('season_id' => '242', 'meeting_url' => 'https://nuoto.ficr.it/#/NUO/x'))
             .to_return(status: 200, body: ok_body)
      gas = stub_request(:get, "#{base_url}pull_results_goandswim")
            .with(query: hash_including('season_id' => '242', 'meeting_url' => 'https://risultati.goandswim.it/evento/abc'))
            .to_return(status: 200, body: ok_body)
      expect(client.pull_ficr(season_id: 242, url: 'https://nuoto.ficr.it/#/NUO/x')).to be_ok
      expect(client.pull_goandswim(season_id: 242, url: 'https://risultati.goandswim.it/evento/abc')).to be_ok
      expect([ficr, gas]).to all(have_been_requested)
    end

    it 'never raises when the crawler server is down' do
      stub_request(:get, /localhost:7000/).to_raise(Errno::ECONNREFUSED)
      expect(client.pull_ficr(season_id: 242, url: 'https://nuoto.ficr.it/#/NUO/x')).to be_unreachable
      expect(client.pull_calendar(season_id: 262, start_url: 'x', sub_menu_type: 'Eventi', year_text: '2025/2026')).to be_unreachable
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
