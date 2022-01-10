# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RowExpandButtonComponent, type: :component do
  let(:fixture_controller_name) { 'api_meeting_reservations' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }

    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    subject(:result) do
      render_inline(
        described_class.new(asset_row: fixture_asset_row, controller_name: fixture_controller_name)
      )
    end

    let(:fixture_asset_row) { GogglesDb::User.all.to_a.sample }
    let(:expected_link_id) { "btn-expand-row-#{fixture_asset_row.id}" }

    it 'has a unique DOM id' do
      expect(result.css("a##{expected_link_id}")).to be_present
    end

    it 'renders the link to the row expand action' do
      expect(result.css("a##{expected_link_id}").attr('href')).to be_present
    end
  end
end
