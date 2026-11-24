# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::PaletteComponent, type: :component do
  subject(:palette) { render_inline(described_class.new(offline:)).at_css("##{described_class::DOM_ID}") }

  let(:offline) { false }

  it 'renders a Bootstrap modal without fade, wired to the palette controller and the Ctrl+K window shortcut' do
    expect(palette['class'].split).to include('modal')
    expect(palette['class'].split).not_to include('fade')
    expect(palette['data-controller']).to eq('palette')
    expect(palette['data-action']).to eq('keydown@window->palette#hotkey')
    expect(palette['aria-labelledby']).to eq('command-palette-title')
    expect(palette['data-palette-min-chars-value']).to eq(Shell::PaletteSearch::MIN_QUERY.to_s)
  end

  it 'embeds every navigation entry as JSON, with the local search URL' do
    entries = JSON.parse(palette['data-palette-entries-value'])
    expect(entries.pluck('key')).to eq(Shell::Navigation::ITEMS.map { |item| item.key.to_s })
    expect(entries.first).to include('label', 'group_label', 'icon', 'path', 'keywords')
    expect(palette['data-palette-search-url-value']).to eq('/palette/search')
  end

  it 'renders the combobox input, the listbox and the live status line' do
    input = palette.at_css('input#command-palette-input')
    expect(input['role']).to eq('combobox')
    expect(input['aria-controls']).to eq('command-palette-results')
    expect(input['data-action']).to eq('input->palette#filter keydown->palette#navigate')
    expect(palette.at_css('#command-palette-results[role="listbox"][data-palette-target="list"]')).to be_present
    expect(palette.at_css('#command-palette-status[role="status"]')['data-searching']).to eq(I18n.t('shell.palette.searching'))
    expect(palette.at_css('#command-palette-empty.d-none').text).to include(I18n.t('shell.palette.no_results'))
  end

  context 'with an API-offline session' do
    let(:offline) { true }

    it 'lists only the offline pages, with no search URL, and says so' do
      keys = JSON.parse(palette['data-palette-entries-value']).pluck('key')
      expect(keys).to match_array(Shell::Navigation::ITEMS.select(&:offline_ok?).map { |item| item.key.to_s })
      expect(palette['data-palette-search-url-value']).to eq('')
      expect(palette.at_css('#command-palette-status').text).to include(I18n.t('shell.palette.offline'))
    end
  end

  describe Shell::PaletteTriggerComponent do
    it 'renders the top bar button opening the palette modal' do
      button = render_inline(described_class.new).at_css('button#palette-trigger')
      expect(button['data-bs-toggle']).to eq('modal')
      expect(button['data-bs-target']).to eq("##{Shell::PaletteComponent::DOM_ID}")
      expect(button['aria-keyshortcuts']).to eq('Control+K Meta+K')
      expect(button['title']).to eq(I18n.t('shell.palette.trigger_title'))
      expect(button['aria-label']).to eq(I18n.t('shell.palette.trigger_title'))
      expect(button.at_css('kbd.app-palette-trigger-extra').text).to eq('Ctrl K')
    end
  end
end
