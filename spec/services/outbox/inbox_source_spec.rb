# frozen_string_literal: true

require 'rails_helper'
require_relative '../inbox/summary_fixtures'

RSpec.describe Outbox::InboxSource do
  include InboxSummaryFixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:items) { described_class.new.items(inbox_context(data_dir: data_root)) }

  after(:each) { FileUtils.rm_rf(data_root) }

  it "takes the 05 ':pending_sql' slot of the registry" do
    expect(described_class.key).to eq(:pending_sql)
    expect(Inbox::Registry.sources).to include(described_class)
    expect(Inbox::Registry.key_for(described_class)).to eq(:pending_sql)
    expect(Inbox::Registry.keys.index(:pending_sql)).to eq(2)
  end

  it 'emits nothing with an empty Outbox' do
    expect(items).to eq([])
  end

  it 'groups the pending scripts in one push item opening the Outbox on the oldest one' do
    create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql')
    create_sql_script(data_root, 'results.new/misc/0011-merge_teams-1-2.sql')
    create_sql_script(data_root, 'results.new/misc/0012-x.sql', state: 'held', held_reason: 'operator')

    expect(items.size).to eq(1)
    item = items.first
    expect(item).to have_attributes(key: 'pending_sql', band: :push, count: 2)
    expect(item.title).to eq(I18n.t('inbox.pending_sql.title', count: 2, number: '0010'))
    expect(item.detail).to include('0010-a-lt4.sql', '0011-merge_teams-1-2.sql')
    expect(item.action.path).to eq('/outbox?focus=0010-a-lt4.sql')
  end

  it 'adds a failed-band item for the pushes in doubt' do
    create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', state: 'in_doubt')
    expect(items.map(&:key)).to eq(['outbox_in_doubt'])
    expect(items.first).to have_attributes(band: :failed)
  end

  it "adds a failed-band 'push failed' item opening the first script failed on the server (phase 08)" do
    script = create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', state: 'failed', remote_iq_id: 9123,
                                                                            remote_error: 'ERROR 1062 (23000) at line 412')
    expect(items.map(&:key)).to eq(['outbox_failed'])
    expect(items.first).to have_attributes(band: :failed, count: 1, title: I18n.t('inbox.pending_sql.failed', count: 1))
    expect(items.first.detail).to eq('0010-a-lt4.sql: ERROR 1062 (23000) at line 412')
    expect(items.first.action.path).to eq("/outbox/#{script.id}")
  end

  it 'notes the held scripts when nothing else is pending' do
    create_sql_script(data_root, 'results.new/normalize/0002-normalize_coded_names.sql', state: 'held', held_reason: 'not_applied_locally')
    expect(items.map(&:key)).to eq(['outbox_held'])
    expect(items.first).to have_attributes(band: :notice)
  end

  it 'falls back to the disk-derived list without the ops DB' do
    write_sql_file(data_root, 'results.new/262/0009-a-lt4.sql')
    items = described_class.new.items(inbox_context(data_dir: data_root, ops_available: false))
    expect(items.map(&:key)).to eq(['pending_sql'])
    expect(items.first.action.path).to eq('/outbox?focus=0009-a-lt4.sql')
  end
end
