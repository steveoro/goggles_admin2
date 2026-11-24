# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::FilterLabelsComponent, type: :component do
  context 'without filter parameters,' do
    subject { render_inline(described_class.new(filter_params: {})).to_html }

    it_behaves_like('any subject that renders nothing')
  end

  context 'with only the ordering parameters,' do
    subject { render_inline(described_class.new(filter_params: { 'order' => 'name', 'descending' => 'true' })).to_html }

    it_behaves_like('any subject that renders nothing')
  end

  context 'with some filter values,' do
    subject(:doc) do
      render_inline(described_class.new(filter_params: { 'name' => 'Ober', 'season_id' => '', 'order' => 'name' }))
    end

    it 'lists the non-blank filters, without the ordering parameters' do
      expect(doc.css('#filter-labels').text.strip).to end_with('name: Ober')
      expect(doc.css('#filter-labels').text).not_to include('season_id', 'order')
    end

    it 'uses the theme-aware secondary text color' do
      expect(doc.css('#filter-labels.text-body-secondary')).to be_present
    end
  end
end
