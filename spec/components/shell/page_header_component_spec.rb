# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::PageHeaderComponent, type: :component do
  let(:crumbs) { [['Entities', nil], ['Teams', '/api_teams']] }

  it 'renders the title, the row counter and the breadcrumbs' do
    html = render_inline(described_class.new(title: 'Teams', count: 42, crumbs:))
    expect(html.at_css('h1 .app-page-title').text).to eq('Teams')
    expect(html.at_css('.app-page-count').text).to eq(I18n.t('dashboard.n_total_rows', tot: 42))
    expect(html.css('nav ol.breadcrumb li').map { |li| li.text.strip }).to eq(%w[Entities Teams])
    expect(html.at_css('ol.breadcrumb li.active')['aria-current']).to eq('page')
  end

  it 'shows a zero counter but hides a nil one' do
    expect(render_inline(described_class.new(title: 'X', count: 0, crumbs:)).at_css('.app-page-count')).to be_present
    expect(render_inline(described_class.new(title: 'X', crumbs:)).at_css('.app-page-count')).to be_nil
  end

  it 'renders the subtitle and the actions slot' do
    html = render_inline(described_class.new(title: 'X', subtitle: 'Some notes', crumbs:)) do |header|
      header.with_actions { '<a id="btn-x" class="btn btn-sm">Go</a>'.html_safe }
    end
    expect(html.at_css('.app-page-subtitle').text).to eq('Some notes')
    expect(html.at_css('.app-page-actions a#btn-x')).to be_present
  end

  it 'defaults the crumbs to the navigation registry for the current request' do
    allow(Shell::Navigation).to receive(:breadcrumbs_for).and_return([['System', nil], ['Settings', '/settings']])
    html = render_inline(described_class.new(title: 'Settings'))
    expect(Shell::Navigation).to have_received(:breadcrumbs_for)
    expect(html.css('ol.breadcrumb li').map { |li| li.text.strip }).to eq(%w[System Settings])
  end

  it 'renders no breadcrumb list without crumbs' do
    expect(render_inline(described_class.new(title: 'X', crumbs: [])).at_css('.breadcrumb')).to be_nil
  end

  it 'provides the page title unless the view already did' do
    view = vc_test_controller.view_context
    described_class.new(title: 'From header', crumbs:).render_in(view)
    expect(view.content_for(:title)).to eq('From header')

    view = vc_test_controller.view_context
    view.provide(:title, 'From view')
    described_class.new(title: 'From header', crumbs:).render_in(view)
    expect(view.content_for(:title)).to eq('From view')
  end
end
