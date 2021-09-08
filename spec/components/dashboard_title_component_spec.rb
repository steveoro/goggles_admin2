# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DashboardTitleComponent, type: :component do
  context 'with valid parameters,' do
    let(:fixture_title) { FFaker::Lorem.words.map(&:titleize).join(' ') }
    let(:fixture_count) { (rand * 1000).to_i }
    let(:rendered_content) do
      render_inline(described_class.new(title: fixture_title, row_count: fixture_count)).to_html
    end

    it 'renders the title' do
      expect(rendered_content).to include(fixture_title)
    end
    it 'renders the row counter' do
      expect(rendered_content).to include(fixture_count.to_s)
    end
  end
end
