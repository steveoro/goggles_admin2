# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::DrillLinkComponent, type: :component do
  it 'renders an icon link with the label as tooltip and accessible name' do
    html = render_inline(described_class.new(path: '/api_badges?badges_grid%5Bswimmer_id%5D=1', icon: 'fa-id-badge',
                                             label: 'Badges', kind: 'badges'))
    link = html.at_css('a.app-drill-link')
    expect(link['href']).to eq('/api_badges?badges_grid%5Bswimmer_id%5D=1')
    expect(link['aria-label']).to eq('Badges')
    expect(link['data-bs-toggle']).to eq('tooltip')
    expect(link['data-bs-title']).to eq('Badges')
    expect(link['data-drill']).to eq('badges')
    expect(link.at_css('i.fa-solid.fa-id-badge[aria-hidden="true"]')).to be_present
  end

  it 'shows the optional text next to the icon (the text is then the accessible name)' do
    link = render_inline(described_class.new(path: '/outbox/1', icon: 'fa-paper-plane', label: 'Open', text: '0042-x.sql'))
           .at_css('a.app-drill-link')
    expect(link.text.strip).to eq('0042-x.sql')
    expect(link['aria-label']).to be_nil
    expect(link['data-drill']).to be_nil
  end

  it 'renders nothing without a path' do
    expect(render_inline(described_class.new(path: nil, icon: 'fa-table-list', label: 'Board')).to_html).to be_empty
  end
end
