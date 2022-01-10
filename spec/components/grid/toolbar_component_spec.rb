# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::ToolbarComponent, type: :component do
  let(:fixture_controller_name) { 'api_import_queues' }

  context 'when some of the required parameters are missing,' do
    subject { render_inline(described_class.new(asset_row: nil, controller_name: fixture_controller_name)).to_html }
    it_behaves_like('any subject that renders nothing')
  end

  let(:fixture_asset_row) { FactoryBot.create(:import_queue) }

  context 'with valid parameters and default options,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(asset_row: fixture_asset_row, controller_name: fixture_controller_name)
      )
    end
    {
      'filter-show-btn' => true,
      'sel-toggle-btn' => true,
      'new-btn' => true,
      'delete-btn' => true,
      'csv-btn' => true
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end

  context 'with valid parameters + disabling the show filters button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          filter: false
        )
      )
    end
    {
      'filter-show-btn' => false,
      'sel-toggle-btn' => true,
      'new-btn' => true,
      'delete-btn' => true,
      'csv-btn' => true
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end

  context 'with valid parameters + disabling the select new button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          select: false
        )
      )
    end
    {
      'filter-show-btn' => true,
      'sel-toggle-btn' => false,
      'new-btn' => true,
      'delete-btn' => true,
      'csv-btn' => true
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end

  context 'with valid parameters + disabling the create new button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          create: false
        )
      )
    end
    {
      'filter-show-btn' => true,
      'sel-toggle-btn' => true,
      'new-btn' => false,
      'delete-btn' => true,
      'csv-btn' => true
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end

  context 'with valid parameters + disabling the delete selection button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          destroy: false
        )
      )
    end
    {
      'filter-show-btn' => true,
      'sel-toggle-btn' => true,
      'new-btn' => true,
      'delete-btn' => false,
      'csv-btn' => true
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end

  context 'with valid parameters + disabling the CSV export button,' do
    let(:expected_delete_link_id) { "frm-delete-row-#{fixture_asset_row.id}" }
    subject do
      render_inline(
        described_class.new(
          asset_row: fixture_asset_row,
          controller_name: fixture_controller_name,
          csv: false
        )
      )
    end
    {
      'filter-show-btn' => true,
      'sel-toggle-btn' => true,
      'new-btn' => true,
      'delete-btn' => true,
      'csv-btn' => false
    }.each do |dom_id, expected_presence|
      it "#{expected_presence ? 'renders' : 'does not render'} the '#{dom_id}' toggle button" do
        expect(subject.css("##{dom_id}").present?).to be expected_presence
      end
    end
  end
end
