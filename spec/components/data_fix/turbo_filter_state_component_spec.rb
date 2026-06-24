# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::TurboFilterStateComponent, type: :component do
  subject(:rendered_node) do
    render_inline(
      described_class.new(
        target_url: '/data_fix/review_teams',
        hidden_params: { file_path: '/tmp/test.json', phase2_v2: 1 },
        per_page_param_name: :teams_per_page,
        per_page_value: 100,
        filter_state:,
        q:,
        filter_label: 'Filter',
        q_min_length: 3,
        q_placeholder: 'Search teams...',
        review_help_text: '(review: unmatched + yellow/red matches)'
      )
    )
  end

  let(:filter_state) { 'review' }
  let(:q) { 'Alpha' }

  it 'renders the auto-submit Stimulus form wrapper' do
    form = rendered_node.css("form[data-controller='data-fix-filter-state']")
    expect(form).to be_present
    expect(form.attr('method').value).to eq('get')
  end

  it 'renders required hidden params' do
    expect(rendered_node.css("input[type='hidden'][name='file_path'][value='/tmp/test.json']")).to be_present
    expect(rendered_node.css("input[type='hidden'][name='phase2_v2'][value='1']")).to be_present
  end

  it 'renders q input with exact value (no trimming)' do
    expect(rendered_node.css("input[type='text'][name='q'][value='Alpha']")).to be_present
  end

  it 'renders q input wired only for local input handling (no auto-submit action)' do
    q_input = rendered_node.css("input[type='text'][name='q']").first
    expect(q_input.attr('data-action')).to eq('input->data-fix-filter-state#handleQInput')
  end

  it 'renders a search submit button next to q input' do
    search_button = rendered_node.css("button[type='submit'][aria-label='Search']")
    expect(search_button).to be_present
    expect(search_button.css('i.fa.fa-search')).to be_present
  end

  it 'renders q_min_length as data attribute' do
    form = rendered_node.css("form[data-controller='data-fix-filter-state']")
    expect(form.attr('data-data-fix-filter-state-q-min-length-value').value).to eq('3')
  end

  it 'renders Bootstrap button group for filter states' do
    expect(rendered_node.css('.btn-group.btn-group-toggle')).to be_present
    expect(rendered_node.css('.btn-group.btn-group-toggle .btn.btn-outline-secondary').count).to eq(3)
  end

  it 'renders the 3-state radio group with current state selected' do
    expect(rendered_node.css("input[type='radio'][name='filter_state'][value='none']")).to be_present
    expect(rendered_node.css("input[type='radio'][name='filter_state'][value='review'][checked='checked']")).to be_present
    expect(rendered_node.css("input[type='radio'][name='filter_state'][value='diff_key']")).to be_present
  end

  it 'renders per-page selector using configured parameter name' do
    expect(rendered_node.css("select[name='teams_per_page']")).to be_present
    expect(rendered_node.css("select[name='teams_per_page'] option[value='100'][selected='selected']")).to be_present
  end

  context 'when filter_state is none and q is present' do
    let(:filter_state) { 'none' }
    let(:q) { 'Alpha' }

    it 'deselects none radio when q is present' do
      expect(rendered_node.css("input[type='radio'][name='filter_state'][value='none'][checked]")).to be_empty
    end

    it 'renders q input with exact value' do
      expect(rendered_node.css("input[type='text'][name='q'][value='Alpha']")).to be_present
    end
  end

  context 'when q includes trailing spaces' do
    let(:q) { 'Alpha ' }

    it 'preserves spaces exactly as typed' do
      expect(rendered_node.css("input[type='text'][name='q'][value='Alpha ']")).to be_present
    end
  end

  context 'when q is empty' do
    let(:q) { '' }

    it 'renders q input as empty' do
      expect(rendered_node.css("input[type='text'][name='q'][value='']")).to be_present
    end
  end
end
