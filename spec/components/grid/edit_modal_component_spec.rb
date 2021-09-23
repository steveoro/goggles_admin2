# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::EditModalComponent, type: :component do
  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(controller_name: nil)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_controller_name) { 'api_users' }
    subject do
      render_inline(
        described_class.new(controller_name: fixture_controller_name)
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
      expect(subject.css('.modal-body#modal-body #frm-modal-edit-appendable')).to be_present
    end
    it 'renders the submit button' do
      expect(subject.css('#btn-submit-save')).to be_present
    end
  end
end
