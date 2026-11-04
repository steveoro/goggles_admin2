# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrawlerLauncher do
  subject(:launcher) { described_class.new(npm_bin: 'fake-npm', wait_for: 1) }

  let(:status_url) { described_class::STATUS_URL }

  describe '#running?' do
    it 'is true when the crawler status endpoint answers' do
      stub_request(:get, status_url).to_return(status: 200, body: '{}')
      expect(launcher.running?).to be true
    end

    it 'is false when the connection is refused' do
      stub_request(:get, status_url).to_raise(Errno::ECONNREFUSED)
      expect(launcher.running?).to be false
    end

    it 'is false on HTTP errors' do
      stub_request(:get, status_url).to_return(status: 500)
      expect(launcher.running?).to be false
    end
  end

  describe '#ensure_running!' do
    before(:each) do
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(described_class::PID_PATH, '4242')
    end

    it 'returns :already_running without spawning anything when the server is up' do
      stub_request(:get, status_url).to_return(status: 200, body: '{}')
      expect(launcher.ensure_running!).to eq(:already_running)
      expect(Process).not_to have_received(:spawn)
    end

    it 'spawns `npm start` in the crawler folder (own process group) and returns :started once it answers' do
      stub_request(:get, status_url).to_raise(Errno::ECONNREFUSED).then.to_return(status: 200, body: '{}')
      expect(launcher.ensure_running!).to eq(:started)
      expect(Process).to have_received(:spawn).with(
        'fake-npm', 'start', hash_including(chdir: Rails.root.join('crawler').to_s, pgroup: true)
      )
      expect(Process).to have_received(:detach).with(4242)
      expect(File).to have_received(:write).with(described_class::PID_PATH, '4242')
    end

    it 'returns :failed when the server never answers' do
      stub_request(:get, status_url).to_raise(Errno::ECONNREFUSED)
      expect(launcher.ensure_running!).to eq(:failed)
    end

    it 'returns :failed when npm cannot be spawned' do
      stub_request(:get, status_url).to_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)
      expect(launcher.ensure_running!).to eq(:failed)
    end
  end

  describe '.flash_for' do
    it 'maps each result to a flash symbol & message' do
      expect(described_class.flash_for(:started).first).to eq(:info)
      expect(described_class.flash_for(:already_running).first).to eq(:notice)
      expect(described_class.flash_for(:failed)).to match([:error, a_string_including('log/crawler.log')])
    end
  end
end
