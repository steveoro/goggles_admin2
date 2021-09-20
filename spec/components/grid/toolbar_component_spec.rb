# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::ToolbarComponent, type: :component do
  let(:fixture_controller_name) { 'import_queues' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  let(:fixture_asset_row) { FactoryBot.create(:import_queue) }

  context 'with valid parameters and default options,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(asset_row: fixture_asset_row, controller_name: fixture_controller_name)
      )
    end
    it 'renders the selection toggle button' do
      expect(subject.css('#sel-toggle-btn')).to be_present
    end
    it 'renders the create new button' do
      expect(subject.css('#new-btn')).to be_present
    end
    it 'renders the delete selection button' do
      expect(subject.css('#delete-btn')).to be_present
    end
    it 'renders the CSV export button' do
      expect(subject.css('#csv-btn')).to be_present
    end
  end

  context 'with valid parameters + disabling the create new button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          create: false
        )
      )
    end
    it 'renders the selection toggle button' do
      expect(subject.css('#sel-toggle-btn')).to be_present
    end
    it 'does not render the create new button' do
      expect(subject.css('#new-btn')).not_to be_present
    end
    it 'renders the delete selection button' do
      expect(subject.css('#delete-btn')).to be_present
    end
    it 'renders the CSV export button' do
      expect(subject.css('#csv-btn')).to be_present
    end
  end

  context 'with valid parameters + disabling the delete selection button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          destroy: false
        )
      )
    end
    it 'renders the selection toggle button' do
      expect(subject.css('#sel-toggle-btn')).to be_present
    end
    it 'renders the create new button' do
      expect(subject.css('#new-btn')).to be_present
    end
    it 'does not render the delete selection button' do
      expect(subject.css('#delete-btn')).not_to be_present
    end
    it 'renders the CSV export button' do
      expect(subject.css('#csv-btn')).to be_present
    end
  end

  context 'with valid parameters + disabling the CSV export button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          csv: false
        )
      )
    end
    it 'renders the selection toggle button' do
      expect(subject.css('#sel-toggle-btn')).to be_present
    end
    it 'renders the create new button' do
      expect(subject.css('#new-btn')).to be_present
    end
    it 'renders the delete selection button' do
      expect(subject.css('#delete-btn')).to be_present
    end
    it 'does not render the CSV export button' do
      expect(subject.css('#csv-btn')).not_to be_present
    end
  end
end
