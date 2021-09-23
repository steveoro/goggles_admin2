# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RowDeleteButtonComponent, type: :component do
  let(:fixture_controller_name) { 'api_users' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_asset_row) { GogglesDb::User.all.to_a.sample }
    let(:expected_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          label_method: 'email'
        )
      )
    end

    it 'renders the link to the row delete action' do
      expect(subject.css('a').attr('href')).to be_present
    end
    it 'has a unique DOM id' do
      expect(subject.css("a##{expected_link_id}")).to be_present
    end
    it 'has a confirmation message setup' do
      expect(subject.css('a').attr('data-confirm').value).to eq(
        I18n.t('dashboard.confirm_row_delete', label: fixture_asset_row.email)
      )
    end
  end
end
