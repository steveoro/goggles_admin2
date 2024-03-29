# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::DeleteSelectionButtonComponent, type: :component do
  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(controller_name: nil)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_controller_name) { 'api_users' }
    subject(:component) do
      render_inline(
        described_class.new(controller_name: fixture_controller_name)
      )
    end

    it 'renders the form for the delete action POST with the proper bindings to the Stimulus JS controller' do
      expect(component.css('#frm-delete-selection')).to be_present
      expect(component.css('#frm-delete-selection').attr('data-controller').value).to eq('grid-selection')
      expect(component.css('#frm-delete-selection').attr('data-grid-selection-target').value).to eq('form')
    end
    it 'includes the hidden field for the IDs payload' do
      expect(component.css('input#ids')).to be_present
      expect(component.css('input#ids').attr('data-grid-selection-target').value).to eq('payload')
    end
    it 'renders the delete-submit button with the proper action binding' do
      expect(component.css('#btn-delete-selection')).to be_present
      expect(component.css('#btn-delete-selection').attr('data-grid-selection-target').value).to eq('btnAction')
      expect(component.css('#btn-delete-selection').attr('data-action').value).to eq('click->grid-selection#handlePost')
    end
  end
end
