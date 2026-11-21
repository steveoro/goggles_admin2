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
  end
end
