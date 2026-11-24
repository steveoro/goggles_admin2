# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sources::FolderListing do
  let(:base_dir) { Pathname.new(Dir.mktmpdir('folder-listing-')).realpath }
  let(:data_root) { base_dir.join('crawler', 'data') }
  let(:guard) { Sources::FileGuard.new(root: data_root) }
  let(:outside_dir) { base_dir.join('outside') }

  def entry(listing, name) = listing.entries.find { |item| item.name == name }

  before(:each) do
    FileUtils.mkdir_p(data_root.join('results.new', '242'))
    File.write(data_root.join('results.new', '242', 'a.json'), '{}')
    FileUtils.mkdir_p(outside_dir)
    3.times { |n| File.write(outside_dir.join("secret-#{n}.txt"), 'x' * 50) }
  end

  after(:each) { FileUtils.rm_rf(base_dir) }

  it 'lists folders first, then files, hiding the dot files' do
    File.write(data_root.join('.keep'), '')
    File.write(data_root.join('season-board.json'), '{}')
    listing = described_class.new(guard:)
    expect(listing.entries.map(&:name)).to eq(%w[results.new season-board.json])
    expect(entry(listing, 'results.new')).to have_attributes(directory?: true, count: 1, outside_link?: false)
    expect(listing).to be_root
  end

  it 'never follows a symlink pointing outside the data root (folder, file or dangling): no size, date, count or link' do
    File.symlink(outside_dir, data_root.join('escape'))
    File.symlink(outside_dir.join('secret-0.txt'), data_root.join('results.new', '242', 'leak.txt'))
    File.symlink(base_dir.join('nowhere'), data_root.join('dangling'))
    listing = described_class.new(guard:)
    expect(entry(listing, 'escape')).to have_attributes(outside_link?: true, directory?: false, count: nil, size: nil, mtime: nil)
    expect(entry(listing, 'dangling')).to have_attributes(outside_link?: true)
    leak = entry(described_class.new(guard:, dir: 'results.new/242'), 'leak.txt')
    expect(leak).to have_attributes(outside_link?: true, size: nil, mtime: nil)
    expect { described_class.new(guard:, dir: 'escape') }.to raise_error(Sources::FileGuard::Refused)
  end

  it 'follows a symlink that stays inside the data root' do
    File.symlink(data_root.join('results.new'), data_root.join('alias'))
    expect(entry(described_class.new(guard:), 'alias')).to have_attributes(outside_link?: false, directory?: true, count: 1)
  end

  it 'gives the crumbs and the parent folder' do
    listing = described_class.new(guard:, dir: 'results.new/242')
    expect(listing.crumbs).to eq([['crawler/data', ''], ['results.new', 'results.new'], %w[242 results.new/242]])
    expect(listing.parent_dir).to eq('results.new')
  end
end
