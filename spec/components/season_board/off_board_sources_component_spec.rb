# frozen_string_literal: true

require 'rails_helper'
require_relative '../../services/season_board/disk_fixtures'

# 0.10.103: the pending sources whose FIN id is on no board row, listed under the board with their actions.
RSpec.describe SeasonBoard::OffBoardSourcesComponent, type: :component do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('off-board') }
  let(:disk_index) { SeasonBoard::DiskIndex.new(season_id: 262, data_dir:) }

  around(:each) { |example| I18n.with_locale(:en) { example.run } }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def render_entries(pipeline: {})
    render_inline(described_class.new(entries: disk_index.entries.values, season_id: 262, pipeline:, csrf_token: 'tok', data_root: data_dir))
  end

  it 'renders nothing without off-board sources' do
    expect(render_inline(described_class.new(entries: [], season_id: 262)).to_html).to be_empty
  end

  it 'lists each source with its FIN id, Open in Sources, Open in Data-Fix and the opt-in Prepare' do
    write_json('results.new', 'eventi-only.json', lt2_hash(fin_id: '150700', results: true))
    page = render_entries
    line = page.at_css('#season-board-off-board li[data-off-board-fin-event-id="150700"]')
    expect(line.text).to include('FIN 150700', 'eventi-only', I18n.t('season_board.off_board.pending.source'))
    links = line.css('a').to_h { |link| [link.text.strip, link['href']] }
    expect(links[I18n.t('season_board.off_board.open_sources')]).to start_with('/sources/results?')
    expect(links[I18n.t('season_board.off_board.open_data_fix')]).to start_with('/data_fix/review_sessions?')
    form = line.at_css('form[action="/sources/prepare"]')
    expect(form.at_css('input[name="path"]')['value']).to eq('results.new/262/eventi-only.json')
    expect(form.at_css('input[name="season_id"]')['value']).to eq('262')
    expect(form.at_css('input[name="authenticity_token"]')['value']).to eq('tok')
    expect(form['data-turbo-confirm']).to eq(I18n.t('season_board.off_board.prepare_confirm'))
    expect(form.at_css('button')['disabled']).to be_nil
  end

  it 'shows the pipeline state and disables Prepare while a preparation is queued or running' do
    write_json('results.new', 'eventi-only.json', lt2_hash(fin_id: '150700', results: true))
    facts = instance_double(SeasonBoard::PipelineIndex::Facts, state_and_detail: [:prepare_queued, {}])
    line = render_entries(pipeline: { 'eventi-only' => facts }).at_css('li[data-off-board-fin-event-id="150700"]')
    expect(line.at_css('[data-off-board-state="prepare_queued"]').text).to eq(I18n.t('season_board.activity.prepare_queued'))
    expect(line.at_css('button[data-off-board-action="prepare"]')).to have_attribute('disabled')
  end

  it 'offers no Prepare for a pending manifest only' do
    write_json('results.done', 'old.json', lt2_hash(fin_id: '150701'))
    write_file('manifests', 'manifest-150701.pdf')
    entries = disk_index.entries.values.select(&:pending?)
    page = render_inline(described_class.new(entries:, season_id: 262, data_root: data_dir))
    expect(page.at_css('form[action="/sources/prepare"]')).to be_nil
  end
end
