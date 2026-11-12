# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FINEventId do
  let(:results_url) do
    'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html' \
      '#/risultati/150091:distanze-speciali-campania-2026.html'
  end
  let(:manifest_url) do
    'https://www.federnuoto.it/component/solrconnect/download.html' \
      '?file=L3Zhci93d3cvZmluX2ZpbGVzL2V2ZW50aS8wMDAwMTUwMDkxLnBkZg=='
  end
  let(:ficr_url) { 'https://nuoto.ficr.it/#/NUO/tempi/25/2026/29/27/AAX/1' }

  describe '.from_results_url' do
    it 'extracts the event ID from a FIN results page URL' do
      expect(described_class.from_results_url(results_url)).to eq('150091')
    end

    it 'is nil for blank, non-FIN or manifest URLs' do
      [nil, '', ficr_url, manifest_url].each do |url|
        expect(described_class.from_results_url(url)).to be_nil
      end
    end
  end

  describe '.from_manifest_url' do
    it 'extracts the event ID (without leading zeros) from a manifest download URL' do
      expect(described_class.from_manifest_url(manifest_url)).to eq('150091')
    end

    it 'handles a URL-escaped Base64 parameter' do
      expect(described_class.from_manifest_url(manifest_url.sub('==', '%3D%3D'))).to eq('150091')
    end

    it 'is nil for blank URLs, results URLs or an undecodable/unrelated file parameter' do
      [nil, '', results_url, ficr_url,
       'https://www.federnuoto.it/component/solrconnect/download.html?file=',
       'https://www.federnuoto.it/component/solrconnect/download.html?file=bm90LWEtcGRm'].each do |url|
        expect(described_class.from_manifest_url(url)).to be_nil
      end
    end
  end

  describe '.parse' do
    it 'returns the same ID for both URL kinds' do
      expect(described_class.parse(results_url)).to eq('150091')
      expect(described_class.parse(manifest_url)).to eq('150091')
    end

    it 'is nil when no ID can be found' do
      expect(described_class.parse(ficr_url)).to be_nil
    end
  end

  describe '.parse_any' do
    it 'returns the first ID found, skipping blank or foreign URLs' do
      expect(described_class.parse_any(nil, ficr_url, manifest_url)).to eq('150091')
    end

    it 'is nil when none of the URLs carries an ID' do
      expect(described_class.parse_any(nil, '', ficr_url)).to be_nil
    end
  end

  describe '.fin_url?' do
    it 'is true for FIN URLs only' do
      expect(described_class.fin_url?(results_url)).to be true
      expect(described_class.fin_url?(manifest_url)).to be true
      expect(described_class.fin_url?(ficr_url)).to be false
      expect(described_class.fin_url?(nil)).to be false
    end
  end
end
