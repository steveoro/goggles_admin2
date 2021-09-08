# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::SelectionToggleButtonComponent, type: :component do
  subject { render_inline(described_class.new) }

  it 'renders the button with the script to toggle the selection of grid rows' do
    expect(subject.css('button.btn')).to be_present
    expect(subject.css('button.btn').attr('onclick').value).to be_present
  end
  it 'includes a tooltip for the button' do
    expect(subject.css('button.btn').attr('data-toggle').value).to eq('tooltip')
    expect(subject.css('button.btn').attr('data-title').value).to be_present
  end
end
