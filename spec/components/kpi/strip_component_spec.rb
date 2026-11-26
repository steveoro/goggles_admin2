# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::StripComponent, type: :component do
  let(:url) { 'http://localhost:8081' }
  let(:taken_at) { Time.zone.parse('2026-11-26 17:06') }
  let(:snapshot) do
    payload = { 'url' => url, 'status' => 'ok', 'values' => { 'api_uses' => 5, 'import_queues' => 0, 'issues' => 1, 'users' => 9 },
                'fetched_at' => %w[api_uses import_queues issues users].index_with { taken_at.iso8601 }, 'errors' => {} }
    instance_double(Ops::Snapshot, payload:, taken_at:)
  end

  # The counter counts the rows still to process (done=false on the API): its label and its link say the same.
  it 'labels the import queues counter as the rows to process and links to the list filtered the same way' do
    node = render_inline(described_class.new(snapshot:, url:)).at_css('a#kpi-tile-import-queues')
    expect(node.text).to include(I18n.t('dashboard.kpis.import_queues'))
    expect(I18n.t('dashboard.kpis.import_queues', locale: :en)).to eq('Import queues to process')
    expect(Rack::Utils.parse_nested_query(URI.parse(node['href']).query)).to eq('import_queues_grid' => { 'done' => 'NO' })
    expect(URI.parse(node['href']).path).to eq('/api_import_queues')
  end

  it 'keeps the plain grid links of the other counters' do
    tile = render_inline(described_class.new(snapshot:, url:)).at_css('a#kpi-tile-users')
    expect(tile['href']).to eq('/api_users')
  end
end
