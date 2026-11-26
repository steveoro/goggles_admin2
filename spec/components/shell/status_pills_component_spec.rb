# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::StatusPillsComponent, type: :component do
  let(:keys) { %i[api crawler queue cable fin_watch ops_db db_sync] }
  let(:checked_at) { Time.zone.parse('2026-11-23 10:15:00') }

  # One result per key: :ok unless listed in +levels+ ({ key => level }).
  def results(levels = {})
    keys.map do |key|
      SystemStatus::Result.new(key:, label: key.to_s.titleize, level: levels.fetch(key, :ok), detail: "#{key} detail", checked_at:)
    end
  end

  def render_pills(results) = render_inline(described_class.new(results:))

  context 'with every probe OK' do
    let(:html) { render_pills(results) }
    let(:summary) { html.at_css("a##{described_class::SUMMARY_ID}") }

    it 'renders only the summary pill, linking to the dashboard System zone (breaking out of the frame)' do
      expect(html.css('.app-status-pill').pluck('id')).to eq([described_class::SUMMARY_ID])
      expect(summary['class']).to include('badge', 'text-bg-success', 'app-status-summary')
      expect(summary['href']).to eq('/#dashboard-system')
      expect(summary['data-turbo-frame']).to eq('_top')
      expect(summary['data-status-level']).to eq('ok')
      expect(summary['data-status-summary']).to eq('all')
      expect(summary.at_css('.app-status-summary-label').text).to eq(I18n.t('shell.status.summary.all_ok'))
      expect(summary['aria-label']).to eq(I18n.t('shell.status.summary.all_ok_aria', count: 7))
    end

    it 'lists every probe with its detail in the (multi-line) tooltip' do
      expect(summary['data-bs-toggle']).to eq('tooltip')
      expect(summary['data-bs-custom-class']).to eq(described_class::TOOLTIP_CLASS)
      lines = summary['data-bs-title'].split("\n")
      expect(lines).to eq(keys.map { |key| "#{key.to_s.titleize}: #{key} detail" } + [I18n.t('shell.status.summary.details')])
    end
  end

  context 'with one warning and one error' do
    let(:html) { render_pills(results(crawler: :warn, db_sync: :error)) }
    let(:summary) { html.at_css("a##{described_class::SUMMARY_ID}") }

    it 'renders those two pills (registry order), then an "N OK" pill for the rest' do
      expect(html.css('.app-status-pill').pluck('id')).to eq(['status-pill-crawler', 'status-pill-db_sync', described_class::SUMMARY_ID])
      expect(html.at_css('#status-pill-crawler')['data-status-level']).to eq('warn')
      expect(html.at_css('#status-pill-db_sync')['data-status-level']).to eq('error')
      expect(summary.at_css('.app-status-summary-label').text).to eq(I18n.t('shell.status.summary.some_ok', count: 5))
      expect(summary['class']).to include('bg-success-subtle')
      expect(summary['data-status-summary']).to eq('rest')
      expect(summary['data-ok-count']).to eq('5')
    end

    it 'lists only the OK probes in the summary tooltip' do
      lines = summary['data-bs-title'].split("\n")
      expect(lines.size).to eq(6)
      expect(lines.join).not_to include('Crawler', 'Db Sync')
      expect(lines.first).to eq('API: api detail') # ('api'.titleize: API is an acronym)
    end
  end

  it 'counts an unknown probe as not OK' do
    html = render_pills(results(api: :unknown))
    expect(html.at_css('#status-pill-api')['data-status-level']).to eq('unknown')
    expect(html.at_css("##{described_class::SUMMARY_ID} .app-status-summary-label").text).to eq('6 OK')
  end

  it 'renders no summary pill when no probe is OK' do
    html = render_pills(results(keys.index_with(:unknown)))
    expect(html.css('.app-status-pill').pluck('id')).to eq(keys.map { |key| "status-pill-#{key}" })
    expect(html.at_css("##{described_class::SUMMARY_ID}")).to be_nil
  end

  it 'falls back to the level name in the tooltip for an OK probe without detail' do
    result = SystemStatus::Result.new(key: :api, label: 'API', level: :ok)
    summary = render_pills([result]).at_css("##{described_class::SUMMARY_ID}")
    expect(summary['data-bs-title'].split("\n").first).to eq("API: #{I18n.t('shell.status.levels.ok')}")
  end

  it 'renders nothing without probes' do
    expect(render_pills([]).to_html).to be_blank
  end

  context 'with the Italian locale' do
    around(:each) { |example| I18n.with_locale(:it) { example.run } }

    it 'labels the summary pill in Italian' do
      expect(render_pills(results).at_css('.app-status-summary-label').text).to eq('Tutto OK')
      expect(render_pills(results(api: :error)).at_css('.app-status-summary-label').text).to eq('6 OK')
    end
  end
end
