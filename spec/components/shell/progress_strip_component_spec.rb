# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::ProgressStripComponent, type: :component do
  subject(:html) { render_inline(described_class.new) }

  let(:strip) { html.at_css("##{described_class::DOM_ID}") }
  let(:panel) { strip.at_css("##{described_class::PANEL_ID}") }

  it 'renders the controller root, never hidden, with the silence delay from its only source' do
    expect(strip['hidden']).to be_nil
    expect(strip['class']).to eq('app-progress-strip')
    expect(strip['data-controller']).to eq('progress-strip')
    expect(strip['data-progress-strip-silence-delay-value']).to eq(described_class::SILENCE_DELAY.to_s)
    expect(described_class::SILENCE_DELAY).to eq(60_000)
  end

  it 'listens to the ImportStatusChannel events and resets before Turbo caches the page' do
    expect(strip['data-action'].split).to contain_exactly(
      'import-status@document->progress-strip#update', 'turbo:before-cache@document->progress-strip#reset'
    )
  end

  it 'keeps an always-rendered polite live region outside the hidden panel' do
    status = strip.at_css('[data-progress-strip-target="status"]')
    expect(status).to have_attributes(name: 'span')
    expect(status['role']).to eq('status')
    expect(status['aria-live']).to eq('polite')
    expect(status['class']).to include('visually-hidden')
    expect(status['hidden']).to be_nil
    expect(status.ancestors.pluck('id')).not_to include(described_class::PANEL_ID)
  end

  it 'renders the visible panel hidden, with aria-hidden texts' do
    expect(panel['hidden']).not_to be_nil
    expect(panel['data-progress-strip-target']).to eq('panel')
    message = panel.at_css('[data-progress-strip-target="message"]')
    expect(message.text).to eq(I18n.t('shell.progress_strip.working'))
    %w[message scope count].each do |target|
      expect(panel.at_css("[data-progress-strip-target='#{target}']")['aria-hidden']).to eq('true')
    end
    expect(panel.at_css('[data-progress-strip-target="scope"]')['hidden']).not_to be_nil
  end

  it 'has an empty progress bar and a labelled close button in the panel' do
    bar = panel.at_css('.progress[role="progressbar"][data-progress-strip-target="progress"]')
    expect(bar['aria-valuenow']).to eq('0')
    expect(bar['aria-label']).to eq(I18n.t('shell.progress_strip.label'))
    expect(bar.at_css('.progress-bar[data-progress-strip-target="bar"]')['style']).to include('width: 0%')

    close = panel.at_css('button.btn-close.app-progress-strip-close[type="button"]')
    expect(close['aria-label']).to eq(I18n.t('shell.progress_strip.close'))
    expect(close['data-action']).to eq('progress-strip#dismiss')
  end

  it 'is never modal (no Bootstrap modal markup, no backdrop)' do
    expect(html.to_html).not_to match(/modal|backdrop|data-bs-/)
  end

  it 'has en and it texts' do
    keys = %w[label working close]
    %i[en it].each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| expect(I18n.t("shell.progress_strip.#{key}", raise: true)).to be_present }
      end
    end
  end
end
