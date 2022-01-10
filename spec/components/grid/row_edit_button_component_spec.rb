# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RowEditButtonComponent, type: :component do
  let(:fixture_controller_name) { 'api_users' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  shared_examples_for('a row edit button with a proper Stimulus JS controller setup') do |namespace_base|
    it 'includes the setup for the Stimulus JS grid-edit controller' do
      expect(subject.css('a').attr('data-controller')).to be_present
      expect(subject.css('a').attr('data-controller').value).to eq('grid-edit')
    end
    it 'sets the modal dialog ID, its base namespace and its action parameters correctly' do
      expect(subject.css('a').attr('data-grid-edit-base-modal-id-value').value).to eq(namespace_base)
      expect(subject.css('a').attr('data-action').value).to eq('click->grid-edit#handleEdit')
    end
  end

  context 'with valid default parameters,' do
    let(:fixture_asset_row) { GogglesDb::User.all.to_a.sample }
    subject do
      render_inline(
        described_class.new(asset_row: fixture_asset_row, controller_name: fixture_controller_name)
      )
    end

    it "renders the link to the 'unnamespaced' default edit modal" do
      expect(subject.css('a').attr('href')).to be_present
      expect(subject.css('a').attr('href').value).to eq('#grid-edit-modal')
    end
    it_behaves_like('a row edit button with a proper Stimulus JS controller setup', 'grid-edit')
  end

  context 'when overriding the base modal ID,' do
    let(:fixture_asset_row) { GogglesDb::User.all.to_a.sample }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          base_modal_id: 'subdetail'
        )
      )
    end

    it "renders the link to the 'subdetail' edit modal" do
      expect(subject.css('a').attr('href')).to be_present
      expect(subject.css('a').attr('href').value).to eq('#subdetail-modal')
    end
    it_behaves_like('a row edit button with a proper Stimulus JS controller setup', 'subdetail')
  end
end
