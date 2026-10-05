# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::OllamaClient, type: :strategy do
  subject(:client) { described_class.new(base_url: 'http://test:11434', model: 'gemma4:e4b') }

  let(:tags_body) do
    { 'models' => [
      { 'name' => 'gemma4:e4b', 'capabilities' => %w[completion vision tools] },
      { 'name' => 'nomic-embed-text:latest', 'capabilities' => %w[embedding] }
    ] }.to_json
  end

  def stub_tags(body)
    response = instance_double(RestClient::Response, body: body)
    allow(RestClient::Request).to receive(:execute)
      .with(hash_including(method: :get, url: 'http://test:11434/api/tags'))
      .and_return(response)
  end

  before(:each) do
    allow(described_class).to receive(:installed?).and_return(true)
  end

  describe '#available?' do
    it 'is true when the binary exists and the API lists models' do
      stub_tags(tags_body)
      expect(client).to be_available
    end

    it 'is false when the API is unreachable' do
      allow(RestClient::Request).to receive(:execute).and_raise(SocketError)
      expect(client).not_to be_available
    end

    it 'is false when the binary is missing' do
      stub_tags(tags_body)
      allow(described_class).to receive(:installed?).and_return(false)
      expect(client).not_to be_available
    end
  end

  describe '#vision_available?' do
    it 'is true when the vision model lists the vision capability' do
      stub_tags(tags_body)
      expect(client).to be_vision_available
    end

    it 'is false when the configured model lacks vision' do
      stub_tags(tags_body)
      visionless = described_class.new(base_url: 'http://test:11434', model: 'nomic-embed-text:latest')
      expect(visionless).not_to be_vision_available
    end
  end

  describe '#generate' do
    let(:generate_response) do
      { 'response' => { 'meeting_name' => 'TEST', 'events' => [] }.to_json }.to_json
    end

    it 'returns the parsed JSON response' do
      response = instance_double(RestClient::Response, body: generate_response)
      allow(RestClient::Request).to receive(:execute)
        .with(hash_including(method: :post, url: 'http://test:11434/api/generate'))
        .and_return(response)
      expect(client.generate(prompt: 'p')).to eq('meeting_name' => 'TEST', 'events' => [])
    end

    it 'uses the vision model and includes images when images are given' do
      response = instance_double(RestClient::Response, body: generate_response)
      captured = nil
      allow(RestClient::Request).to receive(:execute) do |args|
        captured = JSON.parse(args[:payload])
        response
      end
      client.generate(prompt: 'p', images: ['img64'])
      expect(captured['model']).to eq('gemma4:e4b')
      expect(captured['images']).to eq(['img64'])
    end

    it 'raises Error after a retry when the response is not valid JSON' do
      response = instance_double(RestClient::Response, body: { 'response' => 'not json at all' }.to_json)
      allow(RestClient::Request).to receive(:execute).and_return(response)
      expect { client.generate(prompt: 'p') }.to raise_error(described_class::Error, /invalid JSON/)
    end

    it 'wraps API failures in Error' do
      allow(RestClient::Request).to receive(:execute).and_raise(Errno::ECONNREFUSED)
      expect { client.generate(prompt: 'p') }.to raise_error(described_class::Error, /Ollama API request failed/)
    end
  end
end
