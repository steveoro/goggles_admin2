# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require_relative '../summary_fixtures'
require_relative '../../season_board/disk_fixtures'

RSpec.describe Inbox::Sources::PendingSql do
  include InboxSummaryFixtures
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('inbox-sql') }
  let(:items) { described_class.new.items(inbox_context(data_dir:)) }

  after(:each) { FileUtils.remove_entry(data_dir) }

  it 'emits nothing without scripts' do
    expect(items).to eq([])
  end

  it 'groups the season and misc scripts into one item, oldest numeric prefix first' do
    write_file('results.new', '0120-meet-lt4.sql')
    write_file('results.new', '0009-calendar_link-1-2.sql')
    FileUtils.mkdir_p(File.join(data_dir, 'results.new', 'misc'))
    File.write(File.join(data_dir, 'results.new', 'misc', '0100-fix.sql'), '')
    FileUtils.mkdir_p(File.join(data_dir, 'results.new', 'old'))
    File.write(File.join(data_dir, 'results.new', 'old', '0001-ignored.sql'), '')
    write_file('results.new', 'notes.sql')

    expect(items.size).to eq(1)
    item = items.first
    expect(item).to have_attributes(key: 'pending_sql', band: :push, count: 3)
    expect(item.title).to eq(I18n.t('inbox.pending_sql.title', count: 3, number: '0009'))
    expect(item.subject[:sql_path]).to end_with('262/0009-calendar_link-1-2.sql')
    expect(item.action.path).to start_with('/push/index')
  end
end
