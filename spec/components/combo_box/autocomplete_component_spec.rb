# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ComboBox::AutocompleteComponent, type: :component do
  let(:base_name) { 'event_type' }
  let(:jwt) { '<fake_jwt_token>' }
  let(:values) { '<option value="1">25 STILE LIBERO</option>' }

  context 'with default wrapper class' do
    subject(:rendered_node) do
      render_inline(
        described_class.new(
          api_url: nil,
          label: 'Event Type',
          base_name:,
          required: true,
          values:,
          jwt:
        )
      )
    end

    it 'renders the autocomplete-lookup Stimulus controller wrapper' do
      wrapper = rendered_node.css('div.col.autocomplete-lookup')
      expect(wrapper).to be_present
      expect(wrapper.attr('data-controller').value).to eq('autocomplete-lookup')
    end

    it 'renders hidden id and label fields' do
      expect(rendered_node.css("input##{base_name}_id[type='hidden']")).to be_present
      expect(rendered_node.css("input##{base_name}_label[type='hidden']")).to be_present
    end

    it 'renders the TomSelect target select field' do
      select = rendered_node.css("select##{base_name}_select.autocomplete-lookup__select")
      expect(select).to be_present
      expect(select.attr('data-autocomplete-lookup-target').value).to eq('field')
      expect(select.attr('required')).to be_present
    end
  end

  context 'with a custom width-scoped wrapper class' do
    subject(:rendered_node) do
      render_inline(
        described_class.new(
          api_url: nil,
          label: nil,
          base_name:,
          required: true,
          values:,
          wrapper_class: 'w-100 autocomplete-lookup-fixed',
          jwt:
        )
      )
    end

    it 'applies the custom wrapper classes for stable column width' do
      wrapper = rendered_node.css('div.w-100.autocomplete-lookup-fixed.autocomplete-lookup')
      expect(wrapper).to be_present
      expect(wrapper.attr('data-autocomplete-lookup-field-base-name-value').value).to eq(base_name)
    end
  end
end
