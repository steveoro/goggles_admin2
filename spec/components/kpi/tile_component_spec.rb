# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::TileComponent, type: :component do
  let(:fetched_at) { Time.zone.parse('2026-11-23 10:15') }
  let(:formatted) { ActiveSupport::NumberHelper.number_to_delimited(1234, locale: I18n.locale) }

  def tile(**overrides)
    render_inline(described_class.new(key: 'api_uses', label: 'API uses', icon: 'fa-chart-line', value: 1234, fetched_at:,
                                      path: '/stats', **overrides))
  end

  it 'shows the value with its own "as of" time, as a link to its grid' do
    node = tile.at_css('a#kpi-tile-api-uses')
    expect(node['href']).to eq('/stats')
    expect(node['data-turbo-frame']).to eq('_top')
    expect(node.at_css('.kpi-value').text.strip).to eq(formatted)
    expect(node.text).to include(I18n.t('dashboard.kpis.value_as_of', time: I18n.l(fetched_at.localtime, format: :short)))
  end

  it 'shows a real 0 as 0' do
    expect(tile(value: 0).at_css('.kpi-value').text.strip).to eq('0')
  end

  it 'never shows a number for a value never fetched: its state instead' do
    %i[unreachable sign_in unavailable no_data].each do |state|
      node = tile(value: nil, fetched_at: nil, state:).at_css('#kpi-tile-api-uses')
      expect(node.at_css('.kpi-value')).to be_nil
      expect(node.at_css('.kpi-state').text.strip).to eq(I18n.t("dashboard.kpis.states.#{state}"))
      expect(node['data-kpi-state']).to eq(state.to_s)
    end
  end

  it 'keeps a known value next to the state of a failed refresh' do
    node = tile(state: :unreachable).at_css('#kpi-tile-api-uses')
    expect(node.at_css('.kpi-value').text.strip).to eq(formatted)
    expect(node.at_css('.kpi-note').text).to include(I18n.t('dashboard.kpis.states.unreachable'))
  end

  it 'renders without a link when given no path (API-offline session)' do
    expect(tile(path: nil).at_css('div#kpi-tile-api-uses')).to be_present
  end
end
