# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::SqlCreateModalComponent, type: :component do
  let(:fixture_controller_name) { 'api_team_managers' }
  let(:jwt) { '<fake_jwt_token>' }

  context 'when some of the required parameters are missing,' do
    subject do
      render_inline(
        described_class.new(
          controller_name: [fixture_controller_name, nil].sample,
          jwt: nil
        )
      ).to_html
    end

    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid default parameters,' do
    subject(:result) do
      render_inline(
        described_class.new(
          controller_name: fixture_controller_name,
          jwt:
        )
      )
    end

    it 'renders the modal dialog in hidden state' do
      expect(result.css('#sql-create-modal.modal.fade')).to be_present
      expect(result.css('#sql-create-modal.modal.fade.show')).not_to be_present
    end

    it 'includes the form inside the modal dialog' do
      expect(result.css('#sql-create-modal form#frm-sql-create')).to be_present
    end

    it 'posts the form to the sql_create action' do
      form = result.css('form#frm-sql-create')
      expect(form.attr('action').value).to eq('/api_team_managers/sql_create')
      expect(form.attr('method').value).to eq('post')
    end

    it 'includes a title' do
      expect(result.css('#frm-sql-create .modal-title#sql-create-modal-title')).to be_present
    end

    it 'renders a LegacyAutoCompleteComponent widget for each entity (season, team, user)' do
      expect(result.css('.legacy-auto-complete').count).to eq(3)
      # (and no TomSelect-based ComboBox::AutocompleteComponent widget)
      expect(result.css('.autocomplete-lookup')).not_to be_present
    end

    it 'renders a namespaced ID target input for each entity' do
      %w[season team user].each do |entity_name|
        field = result.css("input#sql-create_#{entity_name}_id")
        expect(field).to be_present
        expect(field.attr('name').value).to eq("sql-create[#{entity_name}_id]")
        expect(field.attr('data-legacy-autocomplete-target').value).to eq('field')
      end
    end

    it 'renders a namespaced search input for each entity' do
      %w[season team user].each do |entity_name|
        field = result.css("input#sql-create_#{entity_name}")
        expect(field).to be_present
        expect(field.attr('data-legacy-autocomplete-target').value).to eq('search')
      end
    end

    it 'points each widget to the localhost lookup endpoints, keeping the JWT value' do
      {
        'season' => 'seasons',
        'team' => 'teams',
        'user' => 'users'
      }.each do |entity_name, search_endpoint|
        widget = result.css(".legacy-auto-complete:has(input#sql-create_#{entity_name}_id)").first
        expect(widget['data-controller']).to eq('legacy-autocomplete')
        expect(widget['data-legacy-autocomplete-base-api-url-value']).to eq('/lookup')
        expect(widget['data-legacy-autocomplete-search-endpoint-value']).to eq(search_endpoint)
        expect(widget['data-legacy-autocomplete-detail-endpoint-value']).to eq(entity_name)
        expect(widget['data-legacy-autocomplete-jwt-value']).to eq(jwt)
      end
    end

    it 'renders the cancel & generate buttons' do
      expect(result.css('.modal-footer button[data-dismiss="modal"]')).to be_present
      expect(result.css('.modal-footer button#btn-sql-create-submit-generate[type="submit"]')).to be_present
    end
  end

  context 'when overriding the base DOM ID,' do
    subject(:result) do
      render_inline(
        described_class.new(
          controller_name: fixture_controller_name,
          jwt:,
          base_dom_id: 'custom-ns'
        )
      )
    end

    it 'namespaces the modal, form & widget fields accordingly' do
      expect(result.css('#custom-ns-modal.modal.fade form#frm-custom-ns')).to be_present
      %w[season team user].each do |entity_name|
        field = result.css("input#custom-ns_#{entity_name}_id")
        expect(field).to be_present
        expect(field.attr('name').value).to eq("custom-ns[#{entity_name}_id]")
      end
    end
  end
end
