# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::ScriptRowComponent, type: :component do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:script) do
    create_sql_script(data_root, 'results.new/262/0012-b-lt4.sql', origin: { 'fin_event_id' => '150091', 'meeting_id' => 19_900 })
  end
  let(:blocker) { create_sql_script(data_root, 'results.new/262/0011-a-lt4.sql') }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'renders the row with its link, the blocker, the selection box, the focus and the origin links' do
    render_inline(described_class.new(script:, blocker:, focus: true, selectable: true, preview: ["UPDATE x;\n", true]))
    row = page.find("tr#outbox-script-#{script.id}")
    expect(row['data-outbox-focus']).to eq('true')
    expect(row).to have_link('0012-b-lt4.sql', href: "/outbox/#{script.id}")
    expect(row).to have_text(I18n.t('outbox.blocked_by', file: '0011-a-lt4.sql'))
    expect(row).to have_css("input[type=checkbox][value='#{script.id}']")
    expect(row).to have_link(I18n.t('outbox.origin.fin_event', id: '150091'), href: '/season_board#season-board-row-150091')
    expect(row).to have_text(I18n.t('outbox.origin.meeting', id: 19_900))
    expect(row).to have_css('details pre', text: 'UPDATE x;', visible: :all)
  end

  it 'shows the remote id and push time instead of the origin for the scripts on the server' do
    script.update!(state: 'sent', remote_iq_id: 4321, pushed_at: Time.current)
    render_inline(described_class.new(script:, remote: true, selectable: true))
    expect(page).to have_text('4321')
    expect(page).to have_no_field(type: 'checkbox')
  end
end
