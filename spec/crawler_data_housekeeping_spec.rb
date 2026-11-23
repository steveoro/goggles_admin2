# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe CrawlerDataHousekeeping do
  let(:data_root) { Pathname(Dir.mktmpdir('housekeeping')) }
  let(:now) { Time.zone.now }
  let(:old) { now - 3600 }

  after(:each) { FileUtils.rm_rf(data_root) }

  def folder(rel_path, mtime: old, file: nil)
    path = data_root.join(rel_path)
    FileUtils.mkdir_p(path)
    File.write(path.join(file), 'x') if file
    File.utime(mtime.to_time, mtime.to_time, path)
    path
  end

  it 'removes only old, empty, numeric folders of unknown seasons under the results roots' do
    leftover_new = folder('results.new/518217')
    leftover_sent = folder('results.sent/537501')
    real_season = folder('results.new/242')
    with_file = folder('results.new/518218', file: '0001-x.sql')
    recent = folder('results.new/518219', mtime: now - 5)
    not_numeric = folder('results.new/misc')
    other_root = folder('calendar.done/518220')
    nested = folder('results.new/242/518221')

    removed = described_class.sweep!(data_root:, known_ids: [242], now:)

    expect(removed).to contain_exactly(leftover_new, leftover_sent)
    expect([leftover_new, leftover_sent].map(&:exist?)).to all(be(false))
    expect([real_season, with_file, recent, not_numeric, other_root, nested].map(&:exist?)).to all(be(true))
  end

  it 'keeps the folders of seasons present in the DB when no id list is given' do
    season = GogglesDb::Season.first
    kept = folder("results.new/#{season.id}")
    gone = folder('results.new/999999999')

    expect(described_class.sweep!(data_root:, now:)).to eq([gone])
    expect(kept).to exist
  end

  it 'does nothing when the data root is missing' do
    expect(described_class.sweep!(data_root: data_root.join('nope'), now:)).to eq([])
  end
end
