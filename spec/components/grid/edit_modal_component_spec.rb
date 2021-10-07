# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::EditModalComponent, type: :component do
  context 'when some of the required parameters are missing,' do
    subject do
      render_inline(
        described_class.new(controller_name: [fixture_controller_name, nil].sample, asset_row: nil, jwt: nil)
      ).to_html
    end
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_controller_name) { 'api_users' }
    let(:fixture_asset_row) { GogglesDb::User.new }
    subject do
      render_inline(
        described_class.new(
          controller_name: fixture_controller_name,
          asset_row: fixture_asset_row,
          jwt: nil
        )
      )
    end

    it 'renders the modal dialog in hidden state' do
      expect(subject.css('#grid-edit-modal.modal.fade')).to be_present
      expect(subject.css('#grid-edit-modal.modal.fade.show')).not_to be_present
    end

    it 'includes the edit form inside the modal dialog' do
      expect(subject.css('#grid-edit-modal #frm-modal-edit')).to be_present
    end

    it 'includes a title' do
      expect(subject.css('#frm-modal-edit .modal-title#grid-edit-modal-title')).to be_present
    end

    it 'includes a body' do
      expect(subject.css('#frm-modal-edit .modal-body#modal-body')).to be_present
    end

    it 'includes an input box for each "non-associative" attribute in the model' do
      fixture_asset_row.attributes.each_key do |attr_name|
        # Skip association names because the rendered subject won't sub-render the nested component:
        expect(subject.css("##{attr_name}")).to be_present unless attr_name.ends_with?('_id')
      end
    end

    it 'renders the submit button' do
      expect(subject.css('#btn-submit-save')).to be_present
    end
  end
end
