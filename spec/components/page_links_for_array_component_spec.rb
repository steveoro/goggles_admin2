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

  # NOTE: Full rendering tests with Kaminari pagination are performed in integration tests
  # (spec/requests/data_fix_controller_phase*_spec.rb) where proper routing context exists
end
