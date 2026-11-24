# frozen_string_literal: true

require 'rails_helper'

# Phase 15 exit criterion: no file operation accepts a path outside 'crawler/data' (here a temporary data root).
RSpec.describe Sources::FileGuard do
  subject(:guard) { described_class.new(root: data_root) }

  let(:base_dir) { Pathname.new(Dir.mktmpdir('file-guard-')).realpath }
  let(:data_root) { base_dir.join('crawler', 'data') }
  let(:inside) { data_root.join('results.new', '262', 'meeting.json') }
  let(:outside) { base_dir.join('outside.txt') }

  before(:each) do
    FileUtils.mkdir_p(inside.dirname)
    File.write(inside, '{}')
    File.write(outside, 'secret')
  end

  after(:each) { FileUtils.rm_rf(base_dir) }

  def refusal(&)
    yield
    nil
  rescue described_class::Refused => e
    e.reason
  end

  describe '#resolve!' do
    it 'resolves an absolute path and a path relative to the data root to the real file' do
      expect(guard.resolve!(inside.to_s)).to eq(inside)
      expect(guard.resolve!('results.new/262/meeting.json')).to eq(inside)
      expect(guard.relative(inside)).to eq('results.new/262/meeting.json')
    end

    it 'refuses ../ escapes, relative or absolute' do
      expect(refusal { guard.resolve!('../../outside.txt') }).to eq(:outside)
      expect(refusal { guard.resolve!("#{data_root}/results.new/../../../outside.txt") }).to eq(:outside)
      expect(refusal { guard.resolve!('results.new/262/../../../../outside.txt') }).to eq(:outside)
    end

    it 'refuses an absolute path outside the data root' do
      expect(refusal { guard.resolve!(outside.to_s) }).to eq(:outside)
      expect(refusal { guard.resolve!('/etc/passwd') }).to eq(:outside)
    end

    it 'refuses a symlink pointing out of the data root (file or folder)' do
      File.symlink(outside, data_root.join('results.new', '262', 'link.json'))
      expect(refusal { guard.resolve!('results.new/262/link.json') }).to eq(:outside)
      File.symlink(base_dir, data_root.join('escape'))
      expect(refusal { guard.resolve!('escape/outside.txt') }).to eq(:outside)
    end

    it 'refuses the data root itself, blank paths, NUL bytes, missing files and the wrong type' do
      expect(refusal { guard.resolve!(data_root.to_s) }).to eq(:outside)
      expect(refusal { guard.resolve!('') }).to eq(:blank)
      expect(refusal { guard.resolve!("results.new/262/meeting.json\0.pdf") }).to eq(:blank)
      expect(refusal { guard.resolve!('results.new/262/none.json') }).to eq(:missing)
      expect(refusal { guard.resolve!('results.new/262') }).to eq(:not_a_file)
      expect(refusal { guard.resolve!('results.new/262/meeting.json', type: :directory) }).to eq(:not_a_directory)
      expect(guard.resolve!('results.new/262', type: :directory)).to eq(inside.dirname)
    end

    it 'answers #allowed? without raising' do
      expect(guard.allowed?(inside)).to be true
      expect(guard.allowed?(outside)).to be false
    end
  end

  describe '#resolve_target!' do
    it 'accepts a new path inside the data root, also in a folder still to create' do
      expect(guard.resolve_target!('results.new/262/renamed.json')).to eq(inside.dirname.join('renamed.json'))
      expect(guard.resolve_target!('misc/new/sub/x.csv')).to eq(data_root.join('misc', 'new', 'sub', 'x.csv'))
    end

    it 'refuses a rename target outside the data root (../, absolute, through a symlinked folder)' do
      expect(refusal { guard.resolve_target!('../stolen.json') }).to eq(:outside)
      expect(refusal { guard.resolve_target!(base_dir.join('stolen.json').to_s) }).to eq(:outside)
      expect(refusal { guard.resolve_target!('results.new/../../stolen.json') }).to eq(:outside)
      File.symlink(base_dir, data_root.join('escape'))
      expect(refusal { guard.resolve_target!('escape/stolen.json') }).to eq(:outside)
    end

    it 'refuses an existing target (also a dangling symlink) and the data root itself' do
      expect(refusal { guard.resolve_target!('results.new/262/meeting.json') }).to eq(:exists)
      File.symlink(base_dir.join('nowhere'), data_root.join('dangling'))
      expect(refusal { guard.resolve_target!('dangling') }).to eq(:exists)
      expect(refusal { guard.resolve_target!(data_root.to_s) }).to eq(:exists)
    end
  end
end
