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

  # The goggles_db engine GoggleCup partials keep their Bootstrap 4 markup (shared with goggles_main): the app renders
  # them inside `.goggles-db-partial`, the only place where the Bootstrap 4 classes and data-* attributes still work
  # (compat/_goggles_db_partials.scss + goggles_db_partial_controller.js).
  describe 'journey 11: GogglesCup engine partials (scoped Bootstrap 4 subset)' do
    let(:team) { FactoryBot.create(:team) }
    let(:swimmer) { FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980) }
    let(:cup) do
      FactoryBot.create(:goggle_cup, team:, description: 'Test Cup', season_year: 2025, swimmers_ids: swimmer.id.to_s)
                .tap { |stored| stored.update!(ranking_data: cup_ranking_data) }
    end

    before(:each) do
      query = instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery,
                              call: [{ swimmer_id: swimmer.id, swimmer_name: 'TEST SWIMMER', swimmer_year_of_birth: 1980 }])
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(query)
    end

    # Stored ranking with one scored row and one base timing for the swimmer.
    def cup_ranking_data
      row = { 'event_type_code' => '50SL', 'pool_type_code' => '25', 'meeting_id' => 42, 'meeting_individual_result_id' => 99 }
      {
        description: 'Test Cup', season_year: 2025, max_points: 1000, team_id: team.id, end_date: '2026-07-31',
        swimmer_ids: [swimmer.id], no_duplicated_events: false,
        data: {
          base_timings: { swimmer.id.to_s => [row.merge('season_header_year' => 2022, 'total_hundredths' => 3100,
                                                        'meeting_date' => '2022-02-01', 'meeting_name' => 'Base Meeting')] },
          scores: { swimmer.id.to_s => [row.merge('total_hundredths' => 3000, 'meeting_date' => '2025-01-15',
                                                  'meeting_name' => 'Test Meeting', 'team_id' => team.id, 'team_name' => 'TEST',
                                                  'old_total_hundredths' => 3200, 'old_meeting_date' => '2024-01-10',
                                                  'old_meeting_name' => 'Old Meeting', 'old_meeting_id' => 30,
                                                  'old_meeting_individual_result_id' => 88, 'row_score' => 1066.67)] }
        }
      }.to_json
    end

    def computed_style(selector, property)
      page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).getPropertyValue('#{property}')")
    end

    it 'styles the stored ranking inside the wrapper and opens its base timings through the copied data-bs-toggle' do
      visit(goggles_cup_preview_path(goggle_cup_id: cup.id))
      find_by_id('btn-show-precomputed').click
      expect(page).to have_css('#ranking-panel.show .goggles-db-partial #ranking-results', text: 'TEST SWIMMER')

      wrapper = '#ranking-panel .goggles-db-partial'
      expect(computed_style("#{wrapper} td.text-right", 'text-align')).to eq('right')
      expect(computed_style("#{wrapper} td.pr-4", 'padding-right')).to eq('24px')
      expect(computed_style("#{wrapper} .badge.badge-primary", 'background-color')).not_to eq('rgba(0, 0, 0, 0)')

      toggle = find("#{wrapper} a[data-toggle='collapse']")
      expect(toggle['data-bs-toggle']).to eq('collapse')
      expect(page).to have_no_css("#{wrapper} .collapse.show[id^='base-timings-']")
      toggle.click
      expect(page).to have_css("#{wrapper} .collapse.show[id^='base-timings-']", text: 'Base Meeting')
      expect_no_js_errors
    end

    it 'leaves the Bootstrap 4 classes unstyled outside the wrapper' do
      visit(goggles_cup_preview_path(goggle_cup_id: cup.id))
      expect(page).to have_css('#goggles-cup-selection-form')
      page.execute_script(<<~JS)
        document.body.insertAdjacentHTML('beforeend', '<div id="bs4-probe" class="ml-2 pr-4 text-right">probe</div>')
      JS
      expect(computed_style('#bs4-probe', 'margin-left')).to eq('0px')
      expect(computed_style('#bs4-probe', 'padding-right')).to eq('0px')
      expect(computed_style('#bs4-probe', 'text-align')).not_to eq('right')
      expect_no_js_errors
    end

    it 'renders the base timings page with the engine partial inside the wrapper' do
      visit(base_timings_goggles_cup_preview_path(team_id: team.id, goggle_cup_id: cup.id))

      expect(page).to have_css('#goggles-cup-base-timings .goggles-db-partial #goggle-cup-base-timings', text: 'TEST SWIMMER')
      expect(page).to have_css('.goggles-db-partial td', text: '50SL')
      expect(computed_style('.goggles-db-partial td.text-right', 'text-align')).to eq('right')
      expect(computed_style('.goggles-db-partial small.ml-2', 'margin-left')).to eq('8px')
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
