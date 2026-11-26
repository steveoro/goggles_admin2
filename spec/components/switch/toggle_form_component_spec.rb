# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Switch::ToggleFormComponent, type: :component do
  def render_switch(**overrides)
    defaults = { url: '/automation/switch', name: 'value', checked: true, label: 'Automation', id: 'spec-switch',
                 params: { switch: 'enabled', return_to: 'dashboard' } }
    render_inline(described_class.new(**defaults, **overrides))
  end

  it 'renders a POST form bound to the toggle-submit controller' do
    render_switch(help: 'What it does')
    form = page.find('form.switch-toggle-form')
    expect(form[:action]).to eq('/automation/switch')
    expect(form[:method]).to eq('post')
    expect(form['data-controller']).to eq('toggle-submit')
    expect(form['data-turbo-frame']).to eq('_top')
    expect(form['data-switch-state']).to eq('on')
    expect(page).to have_css('.form-check.form-switch[title="What it does"]')
  end

  it 'renders the Bootstrap switch with its label and the hidden fields' do
    render_switch
    expect(page).to have_field('spec-switch', type: 'checkbox', checked: true)
    switch = page.find('input#spec-switch')
    expect(%i[role name value].map { |attr| switch[attr] }).to eq(%w[switch value 1])
    expect(%w[data-action data-toggle-submit-target].map { |attr| switch[attr] }).to eq(%w[change->toggle-submit#submit input])
    expect(page).to have_css('label.form-check-label[for="spec-switch"]', text: 'Automation')
    expect(page).to have_css('input[type=hidden][name=switch][value=enabled]', visible: :hidden)
    expect(page).to have_css('input[type=hidden][name=return_to][value=dashboard]', visible: :hidden)
    # (the hidden "off" value comes first: the checkbox value wins when the switch is on)
    values = page.all('input[name=value]', visible: :all).map { |input| [input[:type], input[:value]] }
    expect(values).to eq([%w[hidden 0], %w[checkbox 1]])
  end

  it 'renders an unchecked switch with custom values (e.g. the row hold: on posts hold=0)' do
    render_switch(name: 'hold', checked: false, checked_value: '0', unchecked_value: '1', params: { fin_event_id: '13' })
    expect(page).to have_field('spec-switch', type: 'checkbox', checked: false)
    expect(page.find('input#spec-switch')[:value]).to eq('0')
    expect(page).to have_css('input[type=hidden][name=hold][value="1"]', visible: :hidden)
    expect(page.find('form')['data-switch-state']).to eq('off')
  end

  it 'renders a disabled switch with the reason as tooltip of its wrapper and as its (hidden) description' do
    render_switch(disabled: true, reason: 'Forced off', help: 'What it does')
    expect(page.find('input#spec-switch')).to be_disabled
    expect(page).to have_css('.form-check.form-switch[title="Forced off"][data-switch-disabled="true"]')
    expect(page.find('input#spec-switch')['aria-describedby']).to eq('spec-switch-description')
    expect(page).to have_css('span#spec-switch-description.visually-hidden', text: 'Forced off', visible: :all)
  end

  it 'shows the reason as small text when asked, and describes an enabled switch with its help' do
    render_switch(disabled: true, reason: 'No ops DB', reason_visible: true)
    expect(page).to have_css('span#spec-switch-description.small:not(.visually-hidden)', text: 'No ops DB')
    render_switch(help: 'What it does', reason: 'unused', reason_visible: true)
    expect(page).to have_css('span#spec-switch-description.visually-hidden', text: 'What it does', visible: :all)
    expect(render_switch.css('[aria-describedby], [id$="-description"]')).to be_empty
  end

  it 'keeps the server-rendered state for the controller, and opts out of the browser form restore' do
    render_switch(checked: false, disabled: true, reason: 'x')
    form = page.find('form')
    expect([form['data-toggle-submit-checked-value'], form['data-toggle-submit-disabled-value']]).to eq(%w[false true])
    expect(page.find('input#spec-switch')[:autocomplete]).to eq('off')
  end

  it 'uses an explicit authenticity token, extra data attributes and no frame target when asked' do
    render_switch(csrf_token: 'tok-123', turbo_frame: nil, data: { pipeline_action: 'hold' }, form_class: 'flex-grow-1')
    form = page.find('form')
    expect(form['data-turbo-frame']).to be_nil
    expect(form['data-pipeline-action']).to eq('hold')
    expect(form[:class]).to include('flex-grow-1')
    expect(page).to have_css('input[type=hidden][name=authenticity_token][value="tok-123"]', visible: :hidden)
  end

  it 'has no inline event handler' do
    html = render_switch.to_html
    expect(html).not_to match(/\son[a-z]+=/i)
  end
end
