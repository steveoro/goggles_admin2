# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::StatusRowComponent, type: :component do
  let(:checked_at) { Time.zone.parse('2026-11-23 10:15') }

  def row(level, action: nil, key: :crawler)
    result = SystemStatus::Result.new(key:, label: 'Crawler', level:, detail: 'Some detail', checked_at:, action:)
    render_inline(described_class.new(result:)).at_css("#status-row-#{key.to_s.dasherize}")
  end

  it 'shows the label, level, detail and "as of" time' do
    node = row(:warn)
    expect(node['data-status-level']).to eq('warn')
    expect(node.at_css('.badge')['class']).to include('text-bg-warning')
    expect(node.text).to include('Crawler', I18n.t('shell.status.levels.warn'), 'Some detail',
                                 I18n.t('shell.status.as_of', time: I18n.l(checked_at.localtime, format: :short)))
  end

  it 'renders a POST action as a button (e.g. Start crawler)' do
    node = row(:error, action: { label: 'Start crawler', path: '/pull/start_crawler', http_method: :post })
    form = node.at_css('form')
    expect(form['action']).to eq('/pull/start_crawler')
    expect(form.at_css('button').text).to include('Start crawler')
  end

  it 'renders a GET action as a link, and no action area without one' do
    expect(row(:ok, action: { label: 'Open Settings', path: '/settings' }).at_css('a.btn')['href']).to eq('/settings')
    expect(row(:ok).css('a, form')).to be_empty
  end

  it 'uses a dasherized DOM id for multi-word keys' do
    expect(row(:ok, key: :ops_db)).to be_present
  end
end
