# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IssueNavComponent, type: :component do
  it 'wires the issue-nav controller with the totals and the cross-page URLs' do # rubocop:disable RSpec/MultipleExpectations
    nav = DataFix::IssueNav.new(total: 7, offset: 2, prev_url: '/a?teams_page=1#team-card-0', next_url: '/a?teams_page=3#team-card-9')
    render_inline(described_class.new(nav:))
    root = page.find("#data-fix-issue-nav[data-controller='issue-nav']")
    expect(root['data-action']).to eq('keydown@window->issue-nav#keydown')
    expect(root['data-issue-nav-total-value']).to eq('7')
    expect(root['data-issue-nav-offset-value']).to eq('2')
    expect(root['data-issue-nav-prev-url-value']).to eq('/a?teams_page=1#team-card-0')
    expect(root['data-issue-nav-next-url-value']).to eq('/a?teams_page=3#team-card-9')
    expect(root['data-issue-nav-position-label-value']).to include('__CURRENT__').and include('__TOTAL__')
    expect(page).to have_button(I18n.t('data_fix.issue_nav.next'))
    expect(page).to have_css('#btn-issue-prev[data-action="issue-nav#previous"]')
    expect(page).to have_css('#data-fix-issue-position', text: I18n.t('data_fix.issue_nav.total', total: 7))
  end

  it 'disables the buttons without issues and renders the toggle slot' do
    render_inline(described_class.new(nav: nil)) { |component| component.with_toggle { 'TOGGLE' } }
    expect(page).to have_css('#btn-issue-next[disabled]')
    expect(page).to have_css('#data-fix-issue-position', text: I18n.t('data_fix.issue_nav.none'))
    expect(page).to have_text('TOGGLE')
  end
end
