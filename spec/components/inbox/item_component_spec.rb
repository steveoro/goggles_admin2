# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::ItemComponent, type: :component do
  let(:now) { Time.zone.parse('2026-11-23 10:00') }

  def item(**overrides)
    Inbox::Item.new(key: 'board:1:crawl', source: :board_rows, kind: :crawl, band: :acquire, title: 'Crawl: Trofeo X',
                    detail: '08/11 2026 · Roma', since: now - 3.days,
                    action: Inbox::Action.new(label: 'Crawl', path: '/season_board/crawl', http_method: :post, params: { fin_event_id: '1' }),
                    **overrides)
  end

  def render_item(**overrides)
    render_inline(described_class.new(item: item(**overrides), now:))
  end

  it 'renders the title, detail, band and waiting time, keyed by the item key' do
    node = render_item.at_css('li.inbox-item')
    expect(node['data-inbox-key']).to eq('board:1:crawl')
    expect(node['data-inbox-band']).to eq('acquire')
    expect(node.text).to include('Crawl: Trofeo X', '08/11 2026 · Roma', I18n.t('inbox.bands.acquire'))
    expect(node.text).to include(I18n.t('inbox.waiting', ago: I18n.t('datetime.distance_in_words.x_days', count: 3)))
  end

  it 'renders a POST action as a one-button form breaking out of the frame, with its params' do
    form = render_item.at_css('.inbox-item-actions form')
    expect(form['action']).to eq('/season_board/crawl')
    expect(form['data-turbo-frame']).to eq('_top')
    expect(form.at_css('input[name="fin_event_id"]')['value']).to eq('1')
    expect(form.at_css('button').text).to include('Crawl')
  end

  it 'renders a GET action as a link and a DELETE with its confirm' do
    link = render_item(action: Inbox::Action.new(label: 'Open', path: '/remote_writes')).at_css('.inbox-item-actions a.btn')
    expect(link['href']).to eq('/remote_writes')
    expect(link['data-turbo-frame']).to eq('_top')

    purge = Inbox::Action.new(label: 'Purge', path: '/data_fix/sessions/purge', http_method: :delete, confirm: 'Sure?',
                              params: { source_path: 'x.json' })
    form = render_item(action: purge).at_css('.inbox-item-actions form')
    expect(form.at_css('input[name="_method"]')['value']).to eq('delete')
    expect(form['data-turbo-confirm']).to eq('Sure?')
  end

  it 'opens a documentation URL in a new tab' do
    docs = Inbox::Action.new(label: 'How to', path: 'https://github.com/x/y/blob/main/docs/dashboard.md')
    link = render_item(action: docs).at_css('.inbox-item-actions a.btn')
    expect(link['target']).to eq('_blank')
    expect(link['rel']).to eq('noopener')
  end

  it 'shows the group count and the optional secondary action as a small link button' do
    retry_action = Inbox::Action.new(label: 'Retry', path: '/dashboard/retry_failed_job', http_method: :post, params: { id: 1 })
    rendered = render_item(count: 4, secondary_action: retry_action)
    expect(rendered.at_css('.badge').text).to eq('4')
    expect(rendered.css('.inbox-item-actions form').size).to eq(2)
    expect(rendered.at_css('.inbox-item-actions button.btn-link').text).to include('Retry')
  end

  it 'shows the date of a future item instead of a waiting time' do
    expect(render_item(since: now + 2.days).text).not_to include(I18n.t('inbox.waiting', ago: ''))
  end
end
