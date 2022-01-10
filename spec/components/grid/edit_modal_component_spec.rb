# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::EditModalComponent, type: :component do
  let(:fixture_controller_name) { 'api_users' }

  context 'when some of the required parameters are missing,' do
    subject do
      render_inline(
        described_class.new(controller_name: [fixture_controller_name, nil].sample, asset_row: nil, jwt: nil)
      ).to_html
    end
    it_behaves_like('any subject that renders nothing')
  end

  # ASSERT/REQUIRES:
  # - result: the rendered component as a Nokogiri::HTML::DocumentFragment
  shared_examples_for('an edit modal with a proper namespace setup') do |namespace_base|
    it 'renders the modal dialog in hidden state' do
      expect(result.css("##{namespace_base}-modal.modal.fade")).to be_present
      expect(result.css("##{namespace_base}-modal.modal.fade.show")).not_to be_present
    end
    it 'includes the edit form inside the modal dialog' do
      expect(result.css("##{namespace_base}-modal #frm-#{namespace_base}")).to be_present
    end
    it 'includes a title' do
      expect(result.css("#frm-#{namespace_base} .modal-title##{namespace_base}-modal-title")).to be_present
    end
    it 'includes a body' do
      expect(result.css("#frm-#{namespace_base} .modal-body##{namespace_base}-modal-body")).to be_present
    end
    it 'renders the submit button' do
      expect(result.css("#btn-#{namespace_base}-submit-save")).to be_present
    end
  end

  context 'with valid default parameters,' do
    let(:fixture_asset_row) { GogglesDb::ImportQueue.new }
    subject(:result) do
      render_inline(
        described_class.new(
          controller_name: fixture_controller_name,
          asset_row: fixture_asset_row,
          jwt: nil
        )
      )
    end

    it_behaves_like('an edit modal with a proper namespace setup', 'grid-edit')

    it 'includes an input box for each "non-associative" attribute in the model' do
      fixture_asset_row.attributes.each_key do |attr_name|
        # Skip association names because the rendered subject won't sub-render the nested component:
        expect(result.css("##{attr_name}")).to be_present unless attr_name.ends_with?('_id')
      end
    end
  end

  context 'when overriding the base modal ID,' do
    let(:fixture_asset_row) { GogglesDb::ImportQueue.new }
    subject(:result) do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          jwt: nil,
          base_dom_id: 'subdetail'
        )
      )
    end

    it_behaves_like('an edit modal with a proper namespace setup', 'subdetail')

    it 'includes a namespaced input box for each "non-associative" attribute in the model' do
      fixture_asset_row.attributes.each_key do |attr_name|
        # Skip association names because the rendered subject won't sub-render the nested component:
        expect(result.css("#subdetail_#{attr_name}")).to be_present unless attr_name.ends_with?('_id')
      end
    end
  end
end
