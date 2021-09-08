# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::CreateNewButtonComponent, type: :component do
  let(:fixture_controller_name) { 'users' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_asset_row) { GogglesDb::User.new }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name
        )
      )
    end

    it "renders the link to the 'new' edit modal" do
      expect(subject.css('a').attr('href')).to be_present
      expect(subject.css('a').attr('href').value).to eq('#grid-edit-modal')
    end
    it 'includes the setup for the Stimulus JS grid-edit controller' do
      expect(subject.css('a').attr('data-controller')).to be_present
      expect(subject.css('a').attr('data-controller').value).to eq('grid-edit')
    end
    it 'sets the modal dialog ID and action parameters correctly' do
      expect(subject.css('a').attr('data-grid-edit-modal-id-value').value).to eq('grid-edit-modal')
      expect(subject.css('a').attr('data-action').value).to eq('click->grid-edit#handleEdit')
    end
  end
end
