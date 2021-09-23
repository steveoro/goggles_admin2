# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::CsvExportButtonComponent, type: :component do
  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(controller_name: nil, request_params: nil)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  context 'with valid parameters,' do
    let(:fixture_controller_name) { 'api_users' }
    subject do
      render_inline(
        described_class.new(
          controller_name: fixture_controller_name,
          request_params: nil
        )
      )
    end

    it "renders the link to the 'csv' index action" do
      expect(subject.css('a').attr('href')).to be_present
      expect(subject.css('a').attr('href').value).to eq("/#{fixture_controller_name}.csv")
    end
    it 'includes a tooltip help' do
      expect(subject.css('a').attr('data-toggle')).to be_present
      expect(subject.css('a').attr('data-toggle').value).to eq('tooltip')
      expect(subject.css('a').attr('data-title')).to be_present
      expect(subject.css('a').attr('data-title').value).to eq(I18n.t('datagrid.csv_export.btn_tooltip'))
    end
  end
end
