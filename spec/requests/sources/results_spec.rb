# frozen_string_literal: true

require 'rails_helper'

# Results tab and the "Prepare" of a non-FIN source (phase 15).
RSpec.describe 'Sources results' do
  include_context 'with a Sources data root'

  let(:season) { GogglesDb::Season.find(242) }
  let(:fin_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html' }
  let!(:microplus) { write_data('results.new/242/2025-06-24-Riccione-lt4.json', { 'layoutType' => 4, 'name' => 'Riccione', 'sections' => [] }.to_json) }
  let!(:fin_source) do
    write_data('results.new/242/2025-11-08-Trofeo.json', { 'layoutType' => 2, 'name' => 'Trofeo', 'meetingURL' => fin_url, 'sections' => [] }.to_json)
  end

  def html = response.parsed_body

  def row_for(name) = html.at_css("#sources-results-table tr[data-sources-file='#{name}']")

  describe 'GET /sources/results' do
    it 'lists the sources of the season with their FIN id or the non-FIN badge and one primary action' do
      get(sources_results_path(season_id: season.id))
      expect(response).to have_http_status(:success)
      expect(row_for(fin_source.basename.to_s).text).to include('FIN 150091', 'LT2')
      fin_actions = row_for(fin_source.basename.to_s).css('td:last-child a.btn').map { |link| link.text.strip }
      expect(fin_actions).to include(I18n.t('sources.results.actions.open'))
      row = row_for(microplus.basename.to_s)
      expect(row.text).to include(I18n.t('sources.results.badges.non_fin'), 'LT4')
      expect(row.at_css("form[action='#{sources_prepare_path}'] button").text).to include(I18n.t('sources.results.actions.prepare'))
      expect(row.at_css("form[action='#{sources_prepare_path}'] input[name='path']")['value']).to eq('results.new/242/2025-06-24-Riccione-lt4.json')
      expect(html.at_css('#sources-tabs .nav-link.active')['id']).to eq('sources-tab-results')
    end

    # 0.10.102
    it 'labels a FIN source whose FIN id is on no row of the stored board summary' do
      Ops::Snapshot.write!(SeasonBoard::Snapshot.key_for(242), { 'season_id' => 242, 'rows' => [{ 'fin_event_id' => '150999' }] },
                           source: SeasonBoard::Snapshot::SOURCE)
      get(sources_results_path(season_id: season.id))
      badge = row_for(fin_source.basename.to_s).css('.badge').find { |node| node.text.include?('150091') }
      expect(badge.text.strip).to eq(I18n.t('sources.results.badges.off_board', fin_event_id: '150091'))
      expect(badge['title']).to eq(I18n.t('sources.results.badges.off_board_tooltip'))

      Ops::Snapshot.write!(SeasonBoard::Snapshot.key_for(242), { 'season_id' => 242, 'rows' => [{ 'fin_event_id' => '150091' }] },
                           source: SeasonBoard::Snapshot::SOURCE)
      get(sources_results_path(season_id: season.id))
      badge = row_for(fin_source.basename.to_s).css('.badge').find { |node| node.text.include?('150091') }
      expect(badge).to have_attributes(text: 'FIN 150091')
      expect(badge['title']).to eq(I18n.t('sources.results.badges.board_row'))
    end

    it 'shows the Sources item active in the sidebar and Import > Sources > Results as breadcrumbs' do
      get(sources_results_path(season_id: season.id))
      expect(html.css('.app-sidebar a.nav-link.active').pluck('href')).to eq(['/sources/results'])
      expect(html.css('.breadcrumb .breadcrumb-item').map { |crumb| crumb.text.strip }).to include(I18n.t('sources.nav'), I18n.t('sources.tabs.results'))
    end

    it 'remembers the chosen season (ops setting) and falls back to it' do
      get(sources_results_path(season_id: season.id))
      expect(Ops::Setting.fetch(Sources::SEASON_SETTING_KEY)).to eq(242)
      get(sources_results_path)
      expect(html.at_css('#sources-season-select option[selected]')['value']).to eq('242')
      get(sources_results_path(season_id: 99_999_999))
      expect(html.at_css('#sources-season-select option[selected]')['value']).to eq('242')
    end

    it 'says so when the season has no pending source' do
      get(sources_results_path(season_id: 252))
      expect(html.at_css('#sources-results-table-empty')).to be_present
    end
  end

  describe 'POST /sources/prepare' do
    before(:each) { allow(SeasonBoard::Scheduler).to receive(:prepare!).and_return(instance_double(Ops::PipelineRun)) }

    it 'queues the phase 10 prepare of a non-FIN source (operator origin, phases 1-5) and comes back' do
      post(sources_prepare_path, params: { path: 'results.new/242/2025-06-24-Riccione-lt4.json', season_id: 242 })
      expect(SeasonBoard::Scheduler).to have_received(:prepare!)
        .with(season_id: 242, source_path: microplus.to_s, origin: :operator, up_to: 5)
      expect(response).to redirect_to(sources_results_path(season_id: 242, focus: '2025-06-24-Riccione-lt4.json'))
      expect(flash[:notice]).to eq(I18n.t('sources.results.prepare.queued', name: microplus.basename))
    end

    it 'refuses a FIN source (prepared from the Season board)' do
      post(sources_prepare_path, params: { path: 'results.new/242/2025-11-08-Trofeo.json', season_id: 242 })
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
      expect(flash[:warning]).to eq(I18n.t('sources.results.prepare.fin_source'))
    end

    it 'refuses a path outside the season results folder or the data root' do
      other = write_data('calendar.new/242/x.json', '{}')
      post(sources_prepare_path, params: { path: other.to_s, season_id: 242 })
      expect(flash[:warning]).to eq(I18n.t('sources.results.prepare.not_a_source'))
      post(sources_prepare_path, params: { path: '../../../etc/passwd', season_id: 242 })
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.missing'))
      outside = sources_base_dir.join('outside.json')
      File.write(outside, '{}')
      post(sources_prepare_path, params: { path: outside.to_s, season_id: 242 })
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
      expect(SeasonBoard::Scheduler).not_to have_received(:prepare!)
    end

    it 'tells when the scheduler refuses (already prepared, commit pending or no ops DB)' do
      allow(SeasonBoard::Scheduler).to receive(:prepare!).and_return(false)
      post(sources_prepare_path, params: { path: 'results.new/242/2025-06-24-Riccione-lt4.json', season_id: 242 })
      expect(flash[:warning]).to eq(I18n.t('sources.results.prepare.refused', name: microplus.basename))
    end
  end

  # 0.10.99: a non-FIN source has no board activity entry: its queued run is what says "queued".
  it 'shows a disabled "Preparation queued" instead of Prepare / Retry while the prepare of a non-FIN source is queued' do
    source = FactoryBot.create(:ops_pipeline_source, season_id: 242, base: '2025-06-24-Riccione', source_path: microplus.to_s)
    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, kind: 'prepare', origin: 'operator', status: 'queued', subject_key: source.base)
    get(sources_results_path(season_id: 242))
    row = row_for(microplus.basename.to_s)
    expect(row.at_css("form[action='#{sources_prepare_path}']")).to be_nil
    expect(row.at_css('td:last-child span.disabled[aria-disabled="true"]').text).to include(I18n.t('season_board.activity.prepare_queued'))

    source.update!(stage: 'failed')
    get(sources_results_path(season_id: 242))
    row = row_for(microplus.basename.to_s)
    expect(row.at_css("form[action='#{sources_prepare_path}']")).to be_nil
    expect(row.text).to include(I18n.t('season_board.activity.prepare_queued'))
  end

  it 'shows the pipeline state of a prepared non-FIN source with its next step' do
    source = FactoryBot.create(:ops_pipeline_source, season_id: 242, base: '2025-06-24-Riccione', source_path: microplus.to_s,
                                                     stage: 'needs_review', review_phase: 2, review_count: 3)
    (1..5).each { |phase| FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, checked_at: 1.minute.from_now) }
    get(sources_results_path(season_id: 242))
    row = row_for(microplus.basename.to_s)
    expect(row.text).to include(SeasonBoard::StateText.label(:needs_review, step: 2, count: 3))
    expect(row.at_css('td:last-child a.btn').text).to include(I18n.t('sources.results.actions.review', step: 2))
  end
end
