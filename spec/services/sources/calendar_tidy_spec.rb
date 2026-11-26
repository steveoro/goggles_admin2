# frozen_string_literal: true

require 'rails_helper'
require_relative 'cleanup/cleanup_fixtures'

# 0.10.104: the calendar folder tidy-up (calendar.new => calendar.done, never deleted, every move in MOVES.txt).
RSpec.describe Sources::CalendarTidy do
  include CleanupFixtures

  let(:data_dir) { File.realpath(Dir.mktmpdir('calendar-tidy-')) }
  let(:safety) { Sources::Cleanup::Safety.new(season_id: 262, data_root: data_dir, crawler_status: crawler_idle) }
  let(:tidy) { described_class.new(season_id: 262, data_root: data_dir, safety:) }

  def new_rel(name) = "calendar.new/262/#{name}"
  def done_rel(name) = "calendar.done/262/#{name}"

  before(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'moves the superseded originals, the finished selections and the leftovers, never the newest original of a kind' do
    old_file('calendar.new', '20261025-262-3-FIN-current-meetings.csv', 'a')
    old_file('calendar.new', '20261109-262-3-FIN-current-meetings.csv', 'b')
    old_file('calendar.new', '20261125-262-2-FIN-calendar.csv', 'eventi')
    old_file('calendar.new', '20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv', 'sel')
    old_file('calendar.new', '20261125-262-2-FIN-calendar-sel-20261125-110734-892-skip.csv', 'skip')
    before = tree
    outcomes = tidy.call
    expect(outcomes.map(&:status)).to all(eq(:moved))
    moved = %w[20261025-262-3-FIN-current-meetings.csv 20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv
               20261125-262-2-FIN-calendar-sel-20261125-110734-892-skip.csv]
    expect_only_moves(before, tree, moved.to_h { |name| [new_rel(name), done_rel(name)] })
    expect(run_folders.size).to eq(1) # (the journal of the calendar moves lives in the season backup folder)
  end

  it 'treats an original as superseded by a newer one of the same kind already in calendar.done' do
    old_file('calendar.new', '20261101-262-2-FIN-calendar.csv', 'older')
    old_file('calendar.done', '20261125-262-2-FIN-calendar.csv', 'newest')
    expect(tidy.candidates.map { |candidate| [File.basename(candidate.path), candidate.rule] })
      .to eq([['20261101-262-2-FIN-calendar.csv', :calendar_superseded]])
  end

  it 'keeps a file younger than 10 minutes and a selection named by a busy crawl, and moves nothing then' do
    write_file('calendar.new', '20261125-262-2-FIN-calendar-skip.csv', 'fresh')
    selection = old_file('calendar.new', '20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv', 'sel')
    SeasonBoard::ActivityLog.new.queue!('src:sel', kind: :extract, origin: :manual, url: selection, label: File.basename(selection))
    expect(tidy.candidates.map { |candidate| [File.basename(candidate.path), candidate.refusal] }).to contain_exactly(
      ['20261125-262-2-FIN-calendar-skip.csv', :too_recent], ['20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv', :busy_activity]
    )
    before = tree
    expect(tidy.call).to be_empty
    expect(tree).to eq(before)
    expect(run_folders).to be_empty # (no move, no backup folder)
  end

  it 'never overwrites calendar.done: an identical copy goes to the duplicates folder, a different one stays' do
    old_file('calendar.new', '20261109-262-3-FIN-current-meetings-skip.csv', 'same')
    old_file('calendar.done', '20261109-262-3-FIN-current-meetings-skip.csv', 'same')
    other = old_file('calendar.new', '20261110-262-3-FIN-current-meetings-skip.csv', 'new text')
    old_file('calendar.done', '20261110-262-3-FIN-current-meetings-skip.csv', 'old text')
    before = tree
    outcomes = tidy.call
    expect(outcomes.map(&:status)).to eq([:duplicate])
    folder = run_folders.first
    expect_only_moves(before, tree, new_rel('20261109-262-3-FIN-current-meetings-skip.csv') =>
                                      "#{folder}/duplicates/calendar.new/20261109-262-3-FIN-current-meetings-skip.csv")
    expect(tidy.candidates.find { |candidate| candidate.path == other }.refusal).to eq(:name_collision)
  end
end
