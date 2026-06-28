# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ComboBox::AutocompleteTeamComponent, type: :component do
  let(:jwt) { '<fake_jwt_token>' }
  let(:team) { GogglesDb::Team.new(id: 42, name: 'ASD Example') }

  context 'with default label' do
    subject(:rendered_node) do
      render_inline(described_class.new(default_row: team, required: true, jwt:))
    end

    it 'renders the autocomplete-lookup wrapper' do
      wrapper = rendered_node.css('div.col.autocomplete-lookup')
      expect(wrapper).to be_present
      expect(wrapper.attr('data-controller').value).to eq('autocomplete-lookup')
    end

    it 'uses the i18n default label text' do
      label = rendered_node.css('label[for="team"]')
      expect(label).to be_present
      expect(label.text).to eq(I18n.t('best_results.list.team'))
    end

    it 'pre-selects the default row id and name' do
      expect(rendered_node.css('input#team_id[type="hidden"]').attr('value').value).to eq('42')
      expect(rendered_node.css('input#team_label[type="hidden"]').attr('value').value).to eq('ASD Example')
    end
  end

  context 'with a custom label' do
    subject(:rendered_node) do
      render_inline(described_class.new(default_row: nil, label: 'Secondary Team', base_name: 'secondary_team', jwt:))
    end

    it 'renders the custom label text' do
      label = rendered_node.css('label[for="secondary_team"]')
      expect(label).to be_present
      expect(label.text).to eq('Secondary Team')
    end
  end

  context 'with a custom base_name' do
    subject(:rendered_node) do
      render_inline(described_class.new(base_name: 'secondary_team', jwt:))
    end

    it 'uses the custom base_name for hidden fields' do
      expect(rendered_node.css('input#secondary_team_id[type="hidden"]')).to be_present
      expect(rendered_node.css('input#secondary_team_label[type="hidden"]')).to be_present
    end
  end
end
