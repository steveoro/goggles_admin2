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

    it 'renders only http(s) links of the FIN site (0.10.103)' do
      odd = change.merge('added' => [row('Script', url: 'javascript:alert(1)'), row('Elsewhere', url: 'https://evil.example/x.html'),
                                     row('FIN plain', url: 'http://federnuoto.it/a.html')])
      page = render_inline(described_class.new(change: odd))
      hrefs = page.css('a').pluck('href')
      expect(hrefs).not_to include('javascript:alert(1)', 'https://evil.example/x.html')
      expect(hrefs).to include('http://federnuoto.it/a.html')
      expect(page.text).to include('Script', 'Elsewhere')
    end

    it 'renders the check form without CSRF tokens and a link to the Season board' do
      expect(html).to include('action="/federnuoto_watch/check"', 'href="/season_board"')
      expect(html).not_to include('authenticity_token')
    end
  end

  context 'with the progress of the automation (0.10.103)' do
    let(:progress) do
      { 'digest' => 'd1', 'automation' => true, 'actionable' => 3, 'at_parity' => 0, 'calendar' => 'queued', 'awaiting_calendar' => 1,
        'checked_at' => Time.current.iso8601,
        'pending' => [{ 'name' => 'Trofeo A', 'reason' => 'crawling' }, { 'name' => 'Trofeo B', 'reason' => 'crawling' },
                      { 'name' => 'Trofeo C', 'reason' => 'crawl_failed' }] }
    end

    def render_with(progress, digest: 'd1')
      render_inline(described_class.new(change:, digest:, progress:))
    end

    it 'posts the digest of the snapshot shown with the dismiss' do
      expect(render_with(progress).at_css("##{FedernuotoWatch::ALERT_DOM_ID}")['data-federnuoto-watch-ack-digest-value']).to eq('d1')
    end

    it 'lists what the system is doing: the calendar crawl, the meetings being crawled, the ones still waiting' do
      block = render_with(progress).at_css('.federnuoto-watch-progress[data-fin-watch-progress="auto"]')
      expect(block.text).to include(I18n.t('federnuoto_watch.alert.progress.calendar_queued'),
                                    I18n.t('federnuoto_watch.alert.progress.awaiting_calendar', count: 1),
                                    I18n.t('federnuoto_watch.alert.progress.busy.crawling', count: 2),
                                    I18n.t('federnuoto_watch.alert.progress.reasons.crawl_failed', name: 'Trofeo C'),
                                    I18n.t('federnuoto_watch.alert.progress.closes_itself'))
      expect(block.at_css('[data-fin-watch-waiting="1"]')).to be_present
      expect(block.text).not_to include(I18n.t('federnuoto_watch.alert.progress.reasons.crawling', name: 'Trofeo A'))
    end

    it 'says when every meeting with a link is in the pipeline' do
      block = render_with(progress.merge('calendar' => nil, 'awaiting_calendar' => 0, 'pending' => [])).at_css('.federnuoto-watch-progress')
      expect(block.text).to include(I18n.t('federnuoto_watch.alert.progress.nothing_left'))
    end

    it 'tells the operator to do it by hand while the automation is off' do
      node = render_with(progress.merge('automation' => false)).at_css('.federnuoto-watch-progress[data-fin-watch-progress="automation_off"]')
      expect(node.text).to include(I18n.t('federnuoto_watch.alert.progress.automation_off'))
    end

    it 'is not rendered while the automation found nothing actionable in the change' do
      expect(render_with(progress.merge('actionable' => 0)).to_html).to be_empty
      expect(render_with(progress.merge('actionable' => 0, 'automation' => false)).to_html).not_to be_empty
    end

    it 'reads the progress of the stored snapshot only (.from_store)' do
      store = instance_double(FedernuotoWatch::StateStore, read: { 'digest' => 'd1', 'change' => change })
      FedernuotoWatch::Progress.store!(progress.merge('actionable' => 0))
      expect(described_class.from_store(store).render?).to be false
      FedernuotoWatch::Progress.store!(progress.merge('digest' => 'older', 'actionable' => 0))
      expect(described_class.from_store(store).render?).to be true
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
    let(:store) { instance_double(FedernuotoWatch::StateStore, read: { 'digest' => 'd1', 'change' => change }) }

    it 'builds the component from the stored pending change' do
      expect(described_class.from_store(store).render?).to be true
    end
  end
end
