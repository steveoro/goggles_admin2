# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RowToolbarComponent, type: :component do
  # The following controller is the most complete so far (includes the #expand action)
  let(:fixture_controller_name) { 'api_meeting_reservations' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  let(:fixture_asset_row) { GogglesDb::User.all.to_a.sample }
  let(:expected_clone_link_id) { "frm-clone-row-#{fixture_asset_row.id}" }
  let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
  let(:expected_expand_link_id) { "btn-expand-row-#{fixture_asset_row.id}" }

  context 'with valid parameters and default options,' do
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name
        )
      )
    end
    it 'renders the row edit button with the proper bindings' do
      expect(subject.css('.row-edit-btn a').attr('href')).to be_present
      expect(subject.css('.row-edit-btn a').attr('href').value).to eq('#grid-edit-modal')
      expect(subject.css('.row-edit-btn a').attr('data-controller')).to be_present
      expect(subject.css('.row-edit-btn a').attr('data-controller').value).to eq('grid-edit')
      expect(subject.css('.row-edit-btn a').attr('data-grid-edit-base-modal-id-value').value).to eq('grid-edit')
      expect(subject.css('.row-edit-btn a').attr('data-action').value).to eq('click->grid-edit#handleEdit')
    end
    it 'renders the row delete button with the proper bindings' do
      expect(subject.css("a##{expected_delete_link_id}")).to be_present
      expect(subject.css("a##{expected_delete_link_id}").attr('href')).to be_present
    end
    it 'does not render the row clone button' do
      expect(subject.css("##{expected_clone_link_id}")).not_to be_present
    end
    it 'does not render the row expand button' do
      expect(subject.css("##{expected_expand_link_id}")).not_to be_present
    end
  end

  context 'with valid parameters + disabling the row edit button,' do
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          edit: false
        )
      )
    end
    it 'does not render the row edit button' do
      expect(subject.css('.row-edit-btn a')).not_to be_present
    end
    it 'does not render the row expand button' do
      expect(subject.css("##{expected_expand_link_id}")).not_to be_present
    end
    it 'renders the row delete button' do
      expect(subject.css("a##{expected_delete_link_id}")).to be_present
    end
  end

  context 'with valid parameters + disabling the row delete button,' do
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          destroy: false
        )
      )
    end
    it 'renders the row edit button' do
      expect(subject.css('.row-edit-btn a')).to be_present
    end
    it 'does not render the row expand button' do
      expect(subject.css("##{expected_expand_link_id}")).not_to be_present
    end
    it 'does not render the row delete button' do
      expect(subject.css("a##{expected_delete_link_id}")).not_to be_present
    end
  end

  context 'with valid parameters + enabling the row clone button,' do
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: 'api_meetings', # (Currently this is the only controller that supports cloning)
          clone: true,
          destroy: false
        )
      )
    end
    it 'renders the row edit button' do
      expect(subject.css('.row-edit-btn a').attr('href')).to be_present
      expect(subject.css('.row-edit-btn a').attr('href').value).to eq('#grid-edit-modal')
    end
    it 'renders the row clone button' do
      expect(subject.css("a##{expected_clone_link_id}")).to be_present
      expect(subject.css("a##{expected_clone_link_id}").attr('href')).to be_present
    end
    it 'does not render the row expand button' do
      expect(subject.css("##{expected_expand_link_id}")).not_to be_present
    end
    it 'does not render the row delete button' do
      expect(subject.css("a##{expected_delete_link_id}")).not_to be_present
    end
  end

  context 'with valid parameters + enabling the row expand button,' do
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          expand: true
        )
      )
    end
    it 'renders the row edit button with the proper bindings' do
      expect(subject.css('.row-edit-btn a').attr('href')).to be_present
      expect(subject.css('.row-edit-btn a').attr('href').value).to eq('#grid-edit-modal')
      expect(subject.css('.row-edit-btn a').attr('data-controller')).to be_present
      expect(subject.css('.row-edit-btn a').attr('data-controller').value).to eq('grid-edit')
      expect(subject.css('.row-edit-btn a').attr('data-grid-edit-base-modal-id-value').value).to eq('grid-edit')
      expect(subject.css('.row-edit-btn a').attr('data-action').value).to eq('click->grid-edit#handleEdit')
    end
    it 'renders the row expand button with the proper bindings' do
      expect(subject.css("##{expected_expand_link_id}")).to be_present
      expect(subject.css("##{expected_expand_link_id}").attr('href')).to be_present
    end
    it 'renders the row delete button with the proper bindings' do
      expect(subject.css("a##{expected_delete_link_id}")).to be_present
      expect(subject.css("a##{expected_delete_link_id}").attr('href')).to be_present
    end
  end
end
