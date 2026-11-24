# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::PageComponent, type: :component do
  let(:user) { FactoryBot.build(:user, jwt: 'fake-jwt') }
  let(:teams) { GogglesDb::Team.first(2) }
  let(:api_error) { Grid::APIErrorComponent::Error.new(code: 503, detail: 'Service Unavailable', unreachable: false) }

  # (Devise defines #current_user on the controllers when the routes load; Rails 8 loads them lazily)
  before(:each) { Rails.application.reload_routes_unless_loaded }
  after(:each) { TeamsGrid.data_domain = [] }

  # Renders the component as the Teams page would (APITeamsController, /api_teams: no destroy route, as in its view).
  def render_page(error: nil, grid: true, toolbar: { destroy: false }, **options, &)
    with_controller_class(APITeamsController) do
      allow(vc_test_controller).to receive(:current_user).and_return(user)
      with_request_url('/api_teams') do
        TeamsGrid.data_domain = error ? [] : teams
        domain = { count: error ? nil : teams.size, page: 1, per_page: 25, rows: teams, filter_params: {}, index_params: {}, error: }
        args = grid ? { model: GogglesDb::Team, grid: TeamsGrid.new({}) } : {}
        render_inline(described_class.new(title: 'Teams', domain:, toolbar:, **args, **options), &)
      end
    end
  end

  context 'with a grid and the rows of a 200 answer' do
    subject(:html) { render_page }

    it 'renders the page header with the row count' do
      expect(html.at_css('h1 .app-page-title').text).to eq('Teams')
      expect(html.at_css('.app-page-count').text).to eq(I18n.t('dashboard.n_total_rows', tot: teams.size))
    end

    it 'renders the edit modal, the toolbar, the filter form and the table of rows (unchanged DOM ids)' do
      expect(html.at_css('#grid-edit-modal')).to be_present
      %w[filter-show-btn sel-toggle-btn new-btn csv-btn].each do |dom_id|
        expect(html.at_css("section#data-grid ##{dom_id}")).to be_present, dom_id
      end
      expect(html.at_css('section#data-grid #filter-panel form.datagrid-form')['action']).to eq('/api_teams')
      expect(html.css('section#data-grid table.datagrid-table.table.table-hover.table-sm tbody tr').size).to eq(teams.size)
      expect(html.at_css("##{Grid::APIErrorComponent::DOM_ID}")).to be_nil
    end

    it 'passes the toolbar options through' do
      html = render_page(toolbar: { create: false, destroy: false, csv: false })
      expect(html.at_css('#new-btn')).to be_nil
      expect(html.at_css('#delete-btn')).to be_nil
      expect(html.at_css('#csv-btn')).to be_nil
      expect(html.at_css('#filter-show-btn')).to be_present
    end

    it 'renders the toolbar_extra slot inside the toolbar, the actions slot in the header and the content before the table' do
      html = render_page do |page|
        page.with_toolbar_extra { '<div class="btn-group" id="extra-btn">X</div>'.html_safe }
        page.with_actions { '<a id="header-action" href="#">Go</a>'.html_safe }
        '<div id="bespoke-panel"></div>'.html_safe
      end
      expect(html.at_css('.btn-toolbar #extra-btn')).to be_present
      expect(html.at_css('.app-page-actions #header-action')).to be_present
      panel = html.at_css('section#data-grid #bespoke-panel')
      expect(panel).to be_present
      expect(panel.xpath('following::table[contains(@class, "datagrid-table")]')).not_to be_empty
    end
  end

  context 'with a grid after an API error' do
    subject(:html) { render_page(error: api_error) }

    it 'shows the error box instead of the table, keeps the filters and hides the row count' do
      expect(html.at_css("section#data-grid ##{Grid::APIErrorComponent::DOM_ID}")['data-api-error-code']).to eq('503')
      expect(html.at_css('table.datagrid-table')).to be_nil
      expect(html.at_css('#filter-panel form.datagrid-form')).to be_present
      expect(html.at_css('.app-page-count')).to be_nil
    end
  end

  context 'without a grid (bespoke body)' do
    it 'renders the content as the body of the section, with no grid chrome' do
      html = render_page(grid: false, section_id: 'data-list') { '<table id="bespoke-table"></table>'.html_safe }
      expect(html.at_css('section#data-list #bespoke-table')).to be_present
      expect(html.at_css('#grid-edit-modal, .btn-toolbar, form.datagrid-form')).to be_nil
    end

    it 'replaces the body with the error box after an API error, keeping the header actions' do
      html = render_page(grid: false, section_id: 'data-list', error: api_error) do |page|
        page.with_actions { '<a id="header-action" href="#">Go</a>'.html_safe }
        '<table id="bespoke-table"></table>'.html_safe
      end
      expect(html.at_css("section#data-list ##{Grid::APIErrorComponent::DOM_ID}")).to be_present
      expect(html.at_css('#bespoke-table')).to be_nil
      expect(html.at_css('.app-page-actions #header-action')).to be_present
    end
  end
end
