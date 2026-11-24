require "rails_helper"

RSpec.describe PageLinksForArrayComponent, type: :component do
  describe '#initialize' do
    it 'accepts data, total_count, page, and per_page parameters' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3
      )
      expect(component).to be_present
    end

    it 'accepts optional param_name parameter' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3,
        param_name: :teams_page
      )
      expect(component).to be_present
    end

    it 'accepts optional per_page_param parameter' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3,
        per_page_param: :teams_per_page
      )
      expect(component).to be_present
    end

    it 'accepts optional extra_params parameter defaulting to empty hash' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3
      )
      expect(component.instance_variable_get(:@extra_params)).to eq({})

      component_with_params = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3,
        extra_params: { filter_state: 'review', q: 'Alpha' }
      )
      expect(component_with_params.instance_variable_get(:@extra_params)).to eq(filter_state: 'review', q: 'Alpha')
    end
  end

  describe '#render?' do
    it 'returns true when data is an array and counts are positive' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 3
      )
      expect(component.render?).to be true
    end

    it 'returns false when data is not an array' do
      component = described_class.new(
        data: "not an array",
        total_count: 10,
        page: 1,
        per_page: 3
      )
      expect(component.render?).to be false
    end

    it 'returns false when total_count is zero' do
      component = described_class.new(
        data: [],
        total_count: 0,
        page: 1,
        per_page: 3
      )
      expect(component.render?).to be false
    end

    it 'returns false when page is zero or negative' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 0,
        per_page: 3
      )
      expect(component.render?).to be false
    end

    it 'returns false when per_page is zero or negative' do
      component = described_class.new(
        data: [1, 2, 3],
        total_count: 10,
        page: 1,
        per_page: 0
      )
      expect(component.render?).to be false
    end
  end

  describe 'rendering (app/views/kaminari partials)' do
    subject(:doc) do
      with_request_url('/api_teams') do
        render_inline(described_class.new(data: (1..10).to_a, total_count: 200, page: 5, per_page: 10))
      end
    end

    it 'renders each page item with a Bootstrap 5 .page-link as its direct child' do
      expect(doc.css('nav#paginator-controls ul.pagination > li.page-item')).to be_present
      expect(doc.css('ul.pagination > li.page-item > .page-link').size).to eq(doc.css('ul.pagination > li.page-item').size)
    end

    it 'shows the current page as an active, non-link item' do
      expect(doc.css('li.page-item.active[aria-current="page"] > span.page-link').text).to eq('5')
      expect(doc.css('li.page-item.active a')).to be_empty
    end

    it 'renders the truncation gaps as disabled items' do
      expect(doc.css('li.page-item.disabled > span.page-link.gap')).to be_present
    end

    it 'does not reference the legacy #loading-indicator' do
      expect(doc.to_html).not_to include('loading-indicator')
    end
  end

  # NOTE: Further rendering tests with Kaminari pagination are performed in integration tests
  # (spec/requests/data_fix_controller_phase*_spec.rb), with full request parameters
end
