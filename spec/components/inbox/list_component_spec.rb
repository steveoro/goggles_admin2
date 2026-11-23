# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::ListComponent, type: :component do
  def item(key, source)
    Inbox::Item.new(key:, source:, kind: :thing, band: :review, title: key, action: Inbox::Action.new(label: 'Go', path: '/x'))
  end

  it 'renders the empty state' do
    result = Inbox::Builder::Result.new(items: [], hidden: {}, total: 0)
    expect(render_inline(described_class.new(result:)).at_css('#inbox-empty').text).to include(I18n.t('inbox.empty'))
  end

  it 'renders the items and one "N more" line per source, linking to its list page when it has one' do
    result = Inbox::Builder::Result.new(items: [item('a', :board_rows)], hidden: { board_rows: 3, fin_change: 1 }, total: 5)
    rendered = render_inline(described_class.new(result:))
    expect(rendered.css('li.inbox-item').size).to eq(1)
    lines = rendered.css('#inbox-more li')
    expect(lines.map { |line| line.text.strip })
      .to eq([I18n.t('inbox.more', count: 3, source: I18n.t('inbox.sources.board_rows')),
              I18n.t('inbox.more', count: 1, source: I18n.t('inbox.sources.fin_change'))])
    expect(lines.first.at_css('a')['href']).to eq('/season_board')
    expect(lines.last.at_css('a')).to be_nil
  end
end
