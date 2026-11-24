# frozen_string_literal: true

require 'rails_helper'

# Journey (phase 15, run in both themes: SYSTEM_THEME=dark): the command palette (Ctrl+K) opens a meeting found by
# name in the local DB, reaches a sidebar page, moves with the arrow keys, closes with Esc and stays shut while typing
# in a field.
RSpec.describe 'Command palette' do
  let(:admin_user) { prepare_admin_user }
  let!(:meeting) { FactoryBot.create(:meeting, description: 'Trofeo Zqpalette Masters') }

  before(:each) do
    allow(APIProxy).to receive(:ping).and_return(DummyResponse.new(body: { msg: 'OK', version: '7.0' }.to_json))
    # (no scan of the real crawler/data folder)
    allow(DataFix::SessionIndex).to receive(:new).and_return(instance_double(DataFix::SessionIndex, rows: []))
    sign_in_admin(admin_user)
    visit(settings_path)
    expect(page).to have_css('#palette-trigger')
  end

  after(:each) { Ops::Database.reset_state! }

  def press_ctrl_k
    page.driver.browser.action.key_down(:control).send_keys('k').key_up(:control).perform
  end

  # (a page may focus one of its fields on load: the shortcut is then left to the field)
  def blur_focus
    page.execute_script('document.activeElement && document.activeElement.blur()')
  end

  it 'opens with Ctrl+K and opens a meeting found by name with Enter' do
    blur_focus
    press_ctrl_k
    expect(page).to have_css('#command-palette.show')
    expect(page).to have_css('#command-palette-input:focus')

    find_by_id('command-palette-input').send_keys('zqpalette')
    expect(page).to have_css('#command-palette-results a.active[data-palette-kind="meeting"]', text: meeting.description)
    find_by_id('command-palette-input').send_keys(:enter)

    expect(page).to have_current_path(%r{\A/api_meetings\?})
    expect(page).to have_css('h1 .app-page-title', text: I18n.t('dashboard.meetings.title'))
    expect(page).to have_no_css('#command-palette.show')
    expect_no_modal_backdrop
    expect_no_js_errors
  end

  it 'reaches a sidebar page from the top bar trigger, moving with the arrow keys' do
    find_by_id('palette-trigger').click
    expect(page).to have_css('#command-palette.show')
    expect(page).to have_css('#command-palette-results a:first-child.active', text: I18n.t(Shell::Navigation::ITEMS.first.label_key))
    find_by_id('command-palette-input').send_keys(:down)
    expect(page).to have_css('#command-palette-results a:nth-child(2).active[aria-selected="true"]')
    expect(page).to have_css('#command-palette-results a[aria-selected="true"]', count: 1)
    find_by_id('command-palette-input').send_keys(:up, :up)
    expect(page).to have_css('#command-palette-results a:last-child.active')

    outbox = Shell::Navigation.find(:outbox)
    find_by_id('command-palette-input').send_keys(I18n.t(outbox.label_key))
    expect(page).to have_css('#command-palette-results a.active[data-palette-kind="page"]', text: I18n.t(outbox.label_key))
    find_by_id('command-palette-input').send_keys(:enter)

    expect(page).to have_current_path(Shell::Navigation.path_for(outbox))
    expect(page).to have_css(".app-sidebar a.nav-link.active[href=\"#{Shell::Navigation.path_for(outbox)}\"]")
    expect_no_modal_backdrop
    expect_no_js_errors
  end

  it 'closes with Esc and ignores Ctrl+K while typing in a field' do
    blur_focus
    press_ctrl_k
    expect(page).to have_css('#command-palette.show')
    find_by_id('command-palette-input').send_keys(:escape)
    expect(page).to have_no_css('#command-palette.show')
    expect_no_modal_backdrop

    first('main#content input[type="text"]').click
    press_ctrl_k
    sleep(0.3) # (nothing to wait for: the palette must stay shut)
    expect(page).to have_no_css('#command-palette.show')
    expect_no_js_errors
  end
end
