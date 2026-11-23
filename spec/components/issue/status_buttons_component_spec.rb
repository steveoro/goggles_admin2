# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Issue::StatusButtonsComponent, type: :component do
  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_id: nil, asset_status: 1)).to_html }

    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    subject(:doc) { render_inline(described_class.new(asset_id: 42, asset_status: 1)) }

    it 'renders one PUT button for each status except the current one' do
      expect(doc.css('form button').size).to eq(6)
      expect(doc.css('#frm-st-review-42')).to be_empty
      expect(doc.css('#frm-st-new-42, #frm-st-process-42, #frm-st-rejmiss-42').size).to eq(3)
    end

    it 'uses Bootstrap 5 tooltips and spacing on the buttons' do
      button = doc.at_css('#frm-st-new-42')
      expect(button['data-bs-toggle']).to eq('tooltip')
      expect(button['title']).to eq(I18n.t('issues.status_0'))
      expect(button['class'].split).to include('btn-outline-secondary', 'ms-0', 'me-1')
      expect(button['class']).not_to include("'")
    end
  end
end
