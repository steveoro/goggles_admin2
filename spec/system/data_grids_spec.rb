# frozen_string_literal: true

require 'rails_helper'

# Smoke journeys 5-6: Datagrid pages (teams), filter panel, edit modal & selection toggle.
RSpec.describe 'Data grids (api_teams)' do
  let(:admin_user) { prepare_admin_user }
  let!(:teams) { FactoryBot.create_list(:team, 3) }
  # NOTE: the rows are served without a city_id, otherwise the edit modal autocomplete would call
  # the real API server directly from the browser.

  before(:each) do
    allow(APIProxy).to receive(:call)
      .with(hash_including(method: :get, url: 'teams'))
      .and_return(DummyResponse.new(body: teams.map { |team| team.as_json.merge('city_id' => nil) }.to_json))
    sign_in_admin(admin_user)
    visit(api_teams_path)
  end

  describe 'journey 5: rows, filter panel & row edit modal' do
    it 'renders the rows, expands the filter panel and opens/closes the pre-filled edit modal' do # rubocop:disable RSpec/MultipleExpectations
      expect(page).to have_css('#data-grid table tbody tr', count: teams.size)
      teams.each { |team| expect(page).to have_css('#data-grid td', text: team.editable_name) }

      expect(page).to have_no_css('#filter-panel.show')
      find('button[data-target="#filter-panel"]').click
      expect(page).to have_css('#filter-panel.show')

      expect(page).to have_no_css('#grid-edit-modal.show')
      within(:xpath, "//tr[td[contains(., '#{teams.first.editable_name}')]]") do
        find('a[data-action="click->grid-edit#handleEdit"]').click
      end
      expect(page).to have_css('#grid-edit-modal.show')
      expect(find_by_id('editable_name').value).to eq(teams.first.editable_name)

      # (Bootstrap ignores a hide request while the fade-in transition is still running)
      expect(page).to have_css('.modal-backdrop.show')
      sleep(0.6)
      find('#grid-edit-modal .modal-footer [data-bs-dismiss="modal"]').click
      expect(page).to have_no_css('#grid-edit-modal.show')
      expect_no_modal_backdrop
      expect_no_js_errors
    end
  end

  describe 'journey 6: selection toggle' do
    it 'checks every .grid-selector checkbox' do
      expect(page).to have_field(type: 'checkbox', class: 'grid-selector', count: teams.size)
      expect(page).to have_no_field(type: 'checkbox', class: 'grid-selector', checked: true)

      find('button[aria-controls="select-toggle"]').click

      expect(page).to have_field(type: 'checkbox', class: 'grid-selector', checked: true, count: teams.size)
      expect_no_js_errors
    end
  end
end
