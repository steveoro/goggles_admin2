# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutoCompleteComponent, type: :component do
  let(:base_api_url) { "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3" }
  let(:search_endpoint) { 'users' }
  let(:detail_endpoint) { 'user' }
  let(:search_column) { 'name' }
  let(:label_column) { 'email' }
  let(:label2_column) { 'description' }
  let(:jwt) { '<fake_jwt_token>' }

  context 'when some of the required parameters are missing,' do
    subject do
      render_inline(
        described_class.new(
          base_api_url: [base_api_url, nil].sample,
          search_endpoint: [search_endpoint, nil].sample,
          wt: nil
        )
      ).to_html
    end

    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    subject(:rendered_node) do
      render_inline(
        described_class.new(
          base_api_url:, detail_endpoint:,
          search_endpoint:, search_column:,
          label_column:, label2_column:, jwt:
        )
      )
    end

    it 'includes the link to the Stimulus JS controller' do
      expect(rendered_node.css('.form-group').attr('data-controller')).to be_present
      expect(rendered_node.css('.form-group').attr('data-controller').value).to eq('autocomplete')
    end

    it 'includes the base-api-url controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-base-api-url-value')).to be_present
      expect(rendered_node.css('.form-group').attr('data-autocomplete-base-api-url-value').value).to eq(base_api_url)
    end

    it 'includes the search-endpoint controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-search-endpoint-value')).to be_present
      expect(
        rendered_node.css('.form-group').attr('data-autocomplete-search-endpoint-value').value
      ).to eq(search_endpoint)
    end

    it 'includes the detail-endpoint controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-detail-endpoint-value')).to be_present
      expect(
        rendered_node.css('.form-group').attr('data-autocomplete-detail-endpoint-value').value
      ).to eq(detail_endpoint)
    end

    it 'includes the search-column controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-search-column-value')).to be_present
      expect(
        rendered_node.css('.form-group').attr('data-autocomplete-search-column-value').value
      ).to eq(search_column)
    end

    it 'includes the label-column controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-label-column-value')).to be_present
      expect(
        rendered_node.css('.form-group').attr('data-autocomplete-label-column-value').value
      ).to eq(label_column)
    end

    it 'includes the label2-column controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-label2-column-value')).to be_present
      expect(
        rendered_node.css('.form-group').attr('data-autocomplete-label2-column-value').value
      ).to eq(label2_column)
    end

    it 'includes the jwt controller value' do
      expect(rendered_node.css('.form-group').attr('data-autocomplete-jwt-value')).to be_present
      expect(rendered_node.css('.form-group').attr('data-autocomplete-jwt-value').value).to eq(jwt)
    end

    it 'includes the target field input text' do
      expect(rendered_node.css("input.form-control##{detail_endpoint}_id")).to be_present
      expect(
        rendered_node.css("input.form-control##{detail_endpoint}_id").attr('data-autocomplete-target')
      ).to be_present
      expect(
        rendered_node.css("input.form-control##{detail_endpoint}_id").attr('data-autocomplete-target').value
      ).to eq('field')
    end

    it 'includes the search field input text' do
      expect(rendered_node.css("input.form-control##{detail_endpoint}")).to be_present
      expect(
        rendered_node.css("input.form-control##{detail_endpoint}").attr('data-autocomplete-target')
      ).to be_present
      expect(
        rendered_node.css("input.form-control##{detail_endpoint}").attr('data-autocomplete-target').value
      ).to eq('search')
    end

    it 'includes the label description text' do
      expect(rendered_node.css("i.form-text##{detail_endpoint}-desc")).to be_present
      expect(
        rendered_node.css("i.form-text##{detail_endpoint}-desc").attr('data-autocomplete-target')
      ).to be_present
      expect(
        rendered_node.css("i.form-text##{detail_endpoint}-desc").attr('data-autocomplete-target').value
      ).to eq('desc')
    end
  end
end
