# frozen_string_literal: true

require 'rails_helper'

# Smoke journey 11: GogglesCup preview & Stats pages render.
RSpec.describe 'GogglesCup & Stats pages' do
  before(:each) { sign_in_admin(prepare_admin_user) }

  describe 'journey 11: GogglesCup' do
    it 'renders the selection page with the loading overlay hidden' do
      visit(goggles_cup_preview_path)

      expect(page).to have_css('#goggles-cup-selection-form')
      expect(page).to have_css('#goggles-cup-overlay.d-none', visible: :all)
      expect(page).to have_no_css('#goggles-cup-overlay', visible: :visible)
      expect_no_js_errors
    end
  end

  describe 'journey 11: Stats' do
    it 'renders the page with the chart canvas' do
      visit(stats_path)

      expect(page).to have_css('canvas#api-chart')
      expect(page).to have_css('#summary-panels', visible: :all)
      expect_no_js_errors
    end

    it 'redraws the chart with the colours of the new theme when the theme toggles' do
      visit(stats_path)
      expect(page).to have_css('canvas#api-chart')
      grid_color = <<~JS
        Stimulus.getControllerForElementAndIdentifier(document.getElementById('stats-page'), 'chart-api')
                .chart.options.scales.x.grid.color
      JS
      border_color = "getComputedStyle(document.documentElement).getPropertyValue('--bs-border-color').trim()"
      before_toggle = page.evaluate_script(grid_color)
      expect(before_toggle).to eq(page.evaluate_script(border_color))

      find_by_id('theme-toggle').click
      expect(page).to have_css("html[data-bs-theme='#{system_theme == 'dark' ? 'light' : 'dark'}']")
      after_toggle = page.evaluate_script(grid_color)
      expect(after_toggle).not_to eq(before_toggle)
      expect(after_toggle).to eq(page.evaluate_script(border_color))
      expect_no_js_errors
    end
  end
end
