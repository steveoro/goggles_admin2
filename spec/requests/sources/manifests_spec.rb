# frozen_string_literal: true

require 'rails_helper'

# Manifests tab: one extraction path (ManifestExtractJob, per file or the next 20), ported from the former Pull page
# batch specs (preflight blocker, engine choice). The LLM engine is never called.
RSpec.describe 'Sources manifests' do
  include ActiveJob::TestHelper

  include_context 'with a Sources data root'

  let(:client) { instance_double(PdfManifests::DevinClient, available?: true, model_available?: true) }

  def html = response.parsed_body

  def extract_jobs = enqueued_jobs.select { |job| job['job_class'] == 'ManifestExtractJob' }

  before(:each) do
    allow(PdfManifests::ClientFactory).to receive(:build).and_return(client)
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  it 'lists the pending manifests with their state and an Extract action' do
    pdf = write_data('manifests/242/manifest-2026-11-08-Trofeo.pdf', '%PDF')
    write_data('manifests/242/manifest-2026-11-08-Trofeo.txt', 'text')
    write_data('manifests.done/242/manifest-old.pdf', '%PDF')
    SeasonBoard::ActivityLog.new.queue!(SeasonBoard::ActivityLog.source_key('extract', pdf.to_s), kind: :extract, origin: :manual)
    get(sources_manifests_path(season_id: 242, engine: 'ollama'))
    expect(response).to have_http_status(:success)
    row = html.at_css('#sources-manifests-table tr[data-sources-file="manifest-2026-11-08-Trofeo.pdf"]')
    expect(row.text).to include('TXT', I18n.t('sources.manifests.badges.queued'))
    expect(row.at_css('span.btn.disabled').text).to include(I18n.t('sources.manifests.actions.extract'))
    expect(html.at_css('#sources-manifests').text).to include(I18n.t('sources.manifests.counts', pending: 1, done: 1))
    expect(html.at_css('#frm-sources-manifests-batch input[name="engine"]')['value']).to eq('ollama')
  end

  describe 'POST /sources/manifests/extract' do
    let!(:pdf) { write_data('manifests/242/manifest-a.pdf', '%PDF') }

    it 'queues one ManifestExtractJob for the file, logged under its source key' do
      expect { post(sources_manifests_extract_path, params: { pdf_path: 'manifests/242/manifest-a.pdf', season_id: 242, engine: 'devin' }) }
        .to have_enqueued_job(ManifestExtractJob).on_queue('background').with(season_id: 242, pdf_path: pdf.to_s, engine: 'devin')
      entry = SeasonBoard::ActivityLog.new.entry(SeasonBoard::ActivityLog.source_key('extract', pdf.to_s), :extract)
      expect(entry).to have_attributes(status: :queued, label: 'manifest-a.pdf')
      expect(flash[:notice]).to eq(I18n.t('sources.manifests.extract.queued', name: 'manifest-a.pdf'))
      expect { post(sources_manifests_extract_path, params: { pdf_path: pdf.to_s, season_id: 242 }) }.not_to have_enqueued_job(ManifestExtractJob)
      expect(flash[:warning]).to eq(I18n.t('sources.manifests.extract.busy', name: 'manifest-a.pdf'))
    end

    it 'goes through the Season board scheduler for a manifest of a FIN calendar row' do
      fin_url = 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:a.html'
      write_data('results.new/242/a.json', { 'layoutType' => 2, 'meetingURL' => fin_url, 'sections' => [] }.to_json)
      allow(SeasonBoard::Scheduler).to receive(:extract!).and_return(true)
      post(sources_manifests_extract_path, params: { pdf_path: pdf.to_s, season_id: 242 })
      expect(SeasonBoard::Scheduler).to have_received(:extract!).with(season_id: 242, fin_event_id: '150091', engine: nil, pdf_path: pdf.to_s, priority: nil)
    end

    it 'refuses a PDF outside manifests/<season> or outside the data root' do
      other = write_data('pdfs/242/x.pdf', '%PDF')
      [other.to_s, '../../x.pdf', 'manifests/262/../242/../../../x.pdf'].each do |path|
        expect { post(sources_manifests_extract_path, params: { pdf_path: path, season_id: 242 }) }.not_to have_enqueued_job(ManifestExtractJob)
      end
      expect(flash[:warning]).to be_present
    end

    it 'queues the next 20 pending files at priority 10 after the engine preflight' do
      (1..22).each { |n| write_data(format('manifests/242/manifest-%02d.pdf', n), '%PDF') }
      post(sources_manifests_extract_path, params: { batch: 1, season_id: 242, engine: 'ollama' })
      expect(extract_jobs.size).to eq(20)
      expect(extract_jobs.pluck('priority').uniq).to eq([10])
      expect(extract_jobs.map { |job| File.basename(ActiveJob::Arguments.deserialize(job['arguments']).first[:pdf_path]) }.first(2))
        .to eq(%w[manifest-01.pdf manifest-02.pdf])
      expect(flash[:notice]).to eq(I18n.t('sources.manifests.extract.batch_queued', count: 20))
      post(sources_manifests_extract_path, params: { batch: 1, season_id: 242 })
      expect(extract_jobs.size).to eq(23) # (the 20 queued ones are skipped: 3 left)
    end

    it 'reports the preflight blocker and queues nothing' do
      allow(client).to receive_messages(available?: false, engine_name: 'devin', unavailable_hint: 'install it')
      post(sources_manifests_extract_path, params: { batch: 1, season_id: 242 })
      expect(extract_jobs).to be_empty
      expect(flash[:warning]).to eq(I18n.t('sources.manifests.extract.engine_unavailable', engine: 'devin', hint: 'install it'))
    end
  end
end
