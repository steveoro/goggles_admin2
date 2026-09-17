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

  context 'with an asset row including *_id attributes (a GogglesDb::Badge),' do
    let(:fixture_asset_row) { GogglesDb::Badge.new }
    let(:jwt) { '<fake_jwt_token>' }
    # <entity base_name> => <detail endpoint name> (nil for lookup entities)
    let(:expected_id_widgets) do
      {
        'season' => 'season',
        'swimmer' => 'swimmer',
        'team' => 'team',
        'category_type' => 'category_type',
        'entry_time_type' => nil,
        'team_affiliation' => 'team_affiliation'
      }
    end
    subject(:result) do
      render_inline(
        described_class.new(
          controller_name: 'api_badges',
          asset_row: fixture_asset_row,
          jwt:
        )
      )
    end

    it 'renders a LegacyAutoCompleteComponent widget for each "*_id" attribute' do
      expect(result.css('.legacy-auto-complete').count).to eq(expected_id_widgets.count)
      # (and no TomSelect-based ComboBox::AutocompleteComponent widget)
      expect(result.css('.autocomplete-lookup')).not_to be_present
    end

    it 'renders the ID target input for each "*_id" attribute' do
      expected_id_widgets.each_key do |entity_name|
        field = result.css("input##{entity_name}_id")
        expect(field).to be_present
        expect(field.attr('data-legacy-autocomplete-target').value).to eq('field')
      end
    end

    it 'renders the search input for each "*_id" attribute' do
      expected_id_widgets.each_key do |entity_name|
        field = result.css("input##{entity_name}")
        expect(field).to be_present
        expect(field.attr('data-legacy-autocomplete-target').value).to eq('search')
      end
    end

    it 'links each widget to the legacy-autocomplete Stimulus controller with API & JWT values' do
      result.css('.legacy-auto-complete').each do |widget|
        expect(widget['data-controller']).to eq('legacy-autocomplete')
        expect(widget['data-legacy-autocomplete-base-api-url-value']).to end_with('/api/v3')
        expect(widget['data-legacy-autocomplete-jwt-value']).to eq(jwt)
      end
    end

    it 'sets the proper detail endpoint for each "*_id" attribute' do
      expected_id_widgets.each do |entity_name, detail_endpoint|
        widget = result.css(".legacy-auto-complete:has(input##{entity_name}_id)").first
        expect(widget['data-legacy-autocomplete-detail-endpoint-value']).to eq(detail_endpoint)
      end
    end

    it 'sets the proper search endpoint for each "*_id" attribute' do
      expected_id_widgets.each do |entity_name, detail_endpoint|
        widget = result.css(".legacy-auto-complete:has(input##{entity_name}_id)").first
        expected_search = detail_endpoint.nil? ? "lookup/#{entity_name.pluralize}" : detail_endpoint.pluralize
        expect(widget['data-legacy-autocomplete-search-endpoint-value']).to eq(expected_search)
      end
    end

    it 'namespaces the *_id field names when overriding the base modal ID' do
      namespaced = render_inline(
        described_class.new(
          controller_name: 'api_badges',
          asset_row: fixture_asset_row,
          jwt:,
          base_dom_id: 'subdetail'
        )
      )
      expected_id_widgets.each_key do |entity_name|
        field = namespaced.css("input#subdetail_#{entity_name}_id")
        expect(field).to be_present
        expect(field.attr('name').value).to eq("subdetail[#{entity_name}_id]")
      end
    end
  end
end
