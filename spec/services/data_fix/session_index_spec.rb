# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe DataFix::SessionIndex do
  let(:data_dir) { Pathname.new(Dir.mktmpdir) }
  let(:season_dir) { data_dir.join('results.new', '9998') }
  let(:index) { described_class.new(data_dir:) }
  let(:gone_path) { 'crawler/data/results.new/9998/gone-lt4.json' }

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    GogglesDb::DataImportMeetingIndividualResult.where('phase_file_path LIKE ?', '%9998%').delete_all
    GogglesDb::DataImportMeetingRelayResult.where('phase_file_path LIKE ?', '%9998%').delete_all
  end

  after(:each) do
    GogglesDb::DataImportMeetingIndividualResult.where('phase_file_path LIKE ?', '%9998%').delete_all
    GogglesDb::DataImportMeetingRelayResult.where('phase_file_path LIKE ?', '%9998%').delete_all
    FileUtils.remove_entry(data_dir)
  end

  def touch_file(name, mtime: Time.current)
    path = season_dir.join(name)
    File.write(path, '{}')
    File.utime(mtime.to_time, mtime.to_time, path)
    path.to_s
  end

  it 'groups phase files by stem and reports the highest phase and newest mtime' do
    touch_file('meet-lt4.json')
    touch_file('meet-lt4-phase1.json', mtime: 5.days.ago)
    newest = 1.hour.ago
    touch_file('meet-lt4-phase3.json', mtime: newest)
    touch_file('other-lt4-phase1.json')
    touch_file('meet-lt4.orig.json')

    rows = index.rows
    meet = rows.find { |row| row.name == 'meet-lt4.json' }

    expect(rows.size).to eq(2)
    expect(meet.highest_phase).to eq(3)
    expect(meet.season_id).to eq(9998)
    expect(meet.mtime.to_i).to eq(newest.to_i)
    expect(meet.source_exists?).to be true
    expect(meet.staging_rows).to eq(0)
    expect(meet.idle_days).to eq(0)
  end

  it 'ignores non numeric season folders and out-of-range phases' do
    FileUtils.mkdir_p(data_dir.join('results.new', 'misc'))
    File.write(data_dir.join('results.new', 'misc', 'x-phase1.json'), '{}')
    touch_file('meet-lt4-phase6.json')

    expect(index.rows).to be_empty
  end

  it 'adds the staging rows count and lists staging-only sources whose file is gone' do
    touch_file('meet-lt4-phase2.json')
    meet_path = season_dir.join('meet-lt4.json').to_s
    2.times { |i| GogglesDb::DataImportMeetingIndividualResult.create!(import_key: "si-meet-#{i}", phase_file_path: meet_path, rank: 1) }
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'si-gone', phase_file_path: gone_path, rank: 1)

    meet = index.for(meet_path)
    gone = index.for(gone_path)

    expect(meet.staging_rows).to eq(2)
    expect(meet.highest_phase).to eq(2)
    expect(gone.staging_rows).to eq(1)
    expect(gone.highest_phase).to eq(0)
    expect(gone.mtime).to be_nil
    expect(gone.source_exists?).to be false
    expect(gone).to be_orphan
  end

  it 'counts the relay results too, so that a relay-only source is staged (and purgeable)' do
    relay_path = 'crawler/data/results.new/9998/relays-lt4.json'
    meet_path = season_dir.join('meet-lt4.json').to_s
    touch_file('meet-lt4-phase5.json')
    GogglesDb::DataImportMeetingRelayResult.create!(import_key: 'si-relay-1', phase_file_path: relay_path, rank: 1)
    GogglesDb::DataImportMeetingRelayResult.create!(import_key: 'si-relay-2', phase_file_path: relay_path, rank: 2)
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'si-mix-mir', phase_file_path: meet_path, rank: 1)
    GogglesDb::DataImportMeetingRelayResult.create!(import_key: 'si-mix-mrr', phase_file_path: meet_path, rank: 1)

    relays = index.for(relay_path)
    expect(relays.staging_rows).to eq(2)
    expect(relays).to be_staging
    expect(relays).to be_orphan
    expect(index.for(meet_path).staging_rows).to eq(2)
  end

  it 'selects the sessions idle for the given days' do
    touch_file('old-lt4-phase1.json', mtime: 4.days.ago)
    touch_file('new-lt4-phase1.json', mtime: 1.hour.ago)

    expect(index.idle(days: 3).map(&:name)).to eq(['old-lt4.json'])
  end
end
