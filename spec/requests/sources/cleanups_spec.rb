# frozen_string_literal: true

require 'rails_helper'
require_relative '../../services/sources/cleanup/cleanup_fixtures'

# 0.10.104: the clean-up page of the Sources season (dry run, then the operator's apply).
RSpec.describe 'Sources clean-up' do
  include_context 'with a Sources data root'
  include CleanupFixtures

  let(:season_id) { 242 }
  let(:fin_id) { '150091' }
  let(:data_dir) { data_root.to_s } # (CleanupFixtures)
  let(:fin_url) { "#{Sources::CrawlKinds::FIN_RESULTS_BASE_URL}#{fin_id}:x.html" }
  let!(:lt2) do
    age!(write_data("results.new/#{season_id}/2025-11-08-Trofeo.json",
                    { 'layoutType' => 2, 'name' => 'Trofeo', 'meetingURL' => fin_url, 'sections' => [] }.to_json))
  end

  def html = response.parsed_body
  def digest_on_page = html.at_css('#sources-cleanup-form input[name="digest"]')['value']

  before(:each) do
    allow(SeasonBoard::DbIndex).to receive(:new).and_return(db_index_linking(fin_id))
    allow(SystemStatus::CrawlerProbe).to receive(:status_path).and_return(data_root.join('no-crawler-status.json'))
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  describe 'GET /sources/cleanup' do
    it 'lists what would move where, with the plan digest, and moves nothing' do
      get(sources_cleanup_path(season_id:))
      expect(response).to have_http_status(:success)
      row = html.at_css("#sources-cleanup-table tr[data-cleanup-file='2025-11-08-Trofeo.json']")
      expect(row.text).to include("results.backup/#{season_id}/cleanup-<timestamp>/2025-11-08-Trofeo.json",
                                  I18n.t('sources.cleanup.rules.result_free_source'))
      expect(digest_on_page).to eq(Sources::Cleanup::Plan.new(season_id:, data_root:).digest)
      expect(html.at_css('#btn-sources-cleanup-apply')['disabled']).to be_nil
      expect(html.at_css('#sources-cleanup-intro').text).to include(I18n.t('sources.cleanup.intro.nothing_deleted'))
      expect(html.css('.breadcrumb .breadcrumb-item').map { |crumb| crumb.text.strip }).to include(I18n.t('sources.nav'), I18n.t('sources.cleanup.nav'))
      expect(File).to exist(lt2)
    end

    it 'lists the files kept with their reason and the files listed only' do
      age!(write_data("manifests/#{season_id}/manifest-orphan.pdf", '%PDF'))
      age!(write_data("pdfs/#{season_id}/results-res.pdf", '%PDF'))
      get(sources_cleanup_path(season_id:))
      kept = html.at_css("#sources-cleanup-kept li[data-cleanup-file='manifest-orphan.pdf']")
      expect(kept.text).to include(I18n.t('sources.cleanup.reasons.unlinked_meeting'))
      expect(html.at_css("#sources-cleanup-listed-result_pdf li[data-cleanup-file='results-res.pdf']")).to be_present
      expect(html.at_css('#sources-cleanup-listed').text).to include(I18n.t('sources.cleanup.listed.why'))
    end

    it 'labels on the Manifests tab the PDF of a meeting already linked (left out of "Extract next")' do
      age!(write_data("manifests/#{season_id}/manifest-2025-11-08-Trofeo.pdf", '%PDF'))
      get(sources_manifests_path(season_id:))
      row = html.at_css("tr[data-sources-file='manifest-2025-11-08-Trofeo.pdf']")
      expect(row.css('.badge').map { |badge| badge.text.strip }).to include(I18n.t('sources.manifests.badges.linked'))
    end

    it 'is linked from the Results tab with the count of the files to move' do
      get(sources_results_path(season_id:))
      expect(html.at_css('#btn-sources-cleanup').text.strip).to eq(I18n.t('sources.cleanup.link', count: 1))
      expect(html.at_css('#btn-sources-cleanup')['href']).to eq(sources_cleanup_path(season_id:))
    end
  end

  describe 'POST /sources/cleanup' do
    it 'applies the plan the operator saw and comes back with a summary' do
      get(sources_cleanup_path(season_id:))
      post(sources_cleanup_path, params: { season_id:, digest: digest_on_page })
      expect(response).to redirect_to(sources_cleanup_path(season_id:))
      expect(flash[:notice]).to start_with(I18n.t('sources.cleanup.flash.done', moved: 1, skipped: 0, folder: '').split(':').first)
      expect(File).not_to exist(lt2)
      expect(Dir.glob(data_root.join("results.backup/#{season_id}/cleanup-*/2025-11-08-Trofeo.json").to_s).size).to eq(1)
      expect(Ops::Event.where(kind: 'sources.cleanup_applied').last).to have_attributes(season_id:, level: 'success')
      follow_redirect!
      expect(html.at_css('#sources-cleanup-empty')).to be_present
    end

    it 'refuses a second apply of the season while one is running' do
      digest = Sources::Cleanup::Plan.new(season_id:, data_root:).digest
      Sources::Cleanup::ApplyLock.new(season_id).synchronize do
        post(sources_cleanup_path, params: { season_id:, digest: })
      end
      expect(flash[:warning]).to eq(I18n.t('sources.cleanup.flash.refused', reason: I18n.t('sources.cleanup.reasons.apply_running')))
      expect(File).to exist(lt2)
    end

    it 'refuses a digest that no longer matches the files' do
      post(sources_cleanup_path, params: { season_id:, digest: 'stale' })
      expect(response).to redirect_to(sources_cleanup_path(season_id:))
      expect(flash[:warning]).to eq(I18n.t('sources.cleanup.flash.refused', reason: I18n.t('sources.cleanup.reasons.digest_mismatch')))
      expect(File).to exist(lt2)
    end
  end

  context 'without the ops DB' do
    # (the web session lives in the ops DB too: each request signs in again)
    it 'shows the page with the apply button disabled and refuses the apply' do
      digest = Sources::Cleanup::Plan.new(season_id:, data_root:).digest
      allow(Ops).to receive(:available?).and_return(false)
      get(sources_cleanup_path(season_id:))
      expect(response).to have_http_status(:success)
      expect(html.at_css('#sources-cleanup-no-ops')).to be_present
      expect(html.at_css('#btn-sources-cleanup-apply')['disabled']).not_to be_nil
      sign_in_admin(admin_user)
      post(sources_cleanup_path, params: { season_id:, digest: })
      expect(flash[:warning]).to eq(I18n.t('sources.cleanup.flash.refused', reason: I18n.t('sources.cleanup.reasons.ops_unavailable')))
      expect(File).to exist(lt2)
    end
  end
end
