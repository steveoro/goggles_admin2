# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatchAlertComponent, type: :component do
  def row(name, url: '', info: '')
    { 'key' => "2026 | 08/11 | #{name} | Roma", 'year' => '2026', 'date' => '08/11', 'name' => name,
      'place' => 'Roma', 'url' => url, 'info' => info }
  end

  let(:change) do
    {
      'detected_at' => Time.current.iso8601,
      'first_detected_at' => 2.hours.ago.iso8601,
      'added' => (1..12).map { |idx| row("New meeting #{idx}") },
      'removed' => [row('Old meeting')],
      'with_results' => [row('Meeting w/ results', url: 'https://www.federnuoto.it/results/1.html')],
      'updated' => [row('Cancelled meeting', info: 'ANNULLATA')]
    }
  end

  context 'with a pending change' do
    subject(:html) { render_inline(described_class.new(change:)).to_html }

    it 'renders a sticky alert with the expected DOM ID & Stimulus controller' do
      node = render_inline(described_class.new(change:)).at_css("##{FedernuotoWatch::ALERT_DOM_ID}")
      expect(node[:class]).to include('flash-alert', 'flash-sticky')
      expect(node['data-controller']).to eq('federnuoto-watch')
      expect(node['data-federnuoto-watch-ack-url-value']).to eq('/federnuoto_watch/acknowledge')
    end

    it 'lists each section, capping the long ones' do
      expect(html).to include('Old meeting', 'Cancelled meeting', 'ANNULLATA', 'New meeting 10')
      expect(html).not_to include('New meeting 11')
      expect(html).to include(I18n.t('federnuoto_watch.alert.more', count: 2))
    end

    it 'links the meetings with published results' do
      expect(html).to include('href="https://www.federnuoto.it/results/1.html"')
    end

    it 'renders the check form without CSRF tokens and a link to the Season board' do
      expect(html).to include('action="/federnuoto_watch/check"', 'href="/season_board"')
      expect(html).not_to include('action="/federnuoto_watch/pull_calendar"')
      expect(html).not_to include('authenticity_token')
    end
  end

  context 'with a text-only change' do
    it 'renders the text-only notice' do
      html = render_inline(described_class.new(change: { 'detected_at' => Time.current.iso8601 })).to_html
      expect(html).to include(I18n.t('federnuoto_watch.alert.text_only'))
    end
  end

  context 'without a pending change' do
    it 'renders nothing' do
      expect(render_inline(described_class.new(change: nil)).to_html).to be_empty
    end
  end

  describe '.from_store' do
    let(:store) { instance_double(FedernuotoWatch::StateStore, pending_change: change) }

    it 'builds the component from the stored pending change' do
      expect(described_class.from_store(store).render?).to be true
    end
  end
end
