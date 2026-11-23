# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::Builder do
  let(:now) { Time.zone.parse('2026-11-23 10:00') }
  let(:context) { Inbox::Context.new(season: nil, board_snapshot: nil, now:, ops_available: true, api_url: 'http://localhost:8081') }

  # A source class emitting the given items (Hashes of Inbox::Item attributes).
  def source_for(key, *attributes)
    Class.new(Inbox::Source) do
      define_singleton_method(:key) { key }
      define_singleton_method(:name) { "Test#{key.to_s.camelize}" }
      define_method(:items) do |_context|
        attributes.map do |attrs|
          Inbox::Item.new(source: key, kind: :thing, title: attrs[:key], action: Inbox::Action.new(label: 'Go', path: '/x'), **attrs)
        end
      end
    end
  end

  it 'sorts by band, then oldest first' do
    source = source_for(:a, { key: 'notice', band: :notice, since: now - 9.days },
                        { key: 'push-new', band: :push, since: now - 1.hour }, { key: 'push-old', band: :push, since: now - 2.days },
                        { key: 'blocked', band: :blocked, since: now })
    expect(described_class.new(sources: [source]).call(context).items.map(&:key)).to eq(%w[blocked push-old push-new notice])
  end

  it 'keeps one item per key: the most urgent one' do
    board = source_for(:board_rows, { key: 'board:1:crawl', band: :acquire, since: now - 1.day })
    failed = source_for(:failed_jobs, { key: 'board:1:crawl', band: :failed, since: now })
    items = described_class.new(sources: [board, failed]).call(context).items
    expect(items.map { |item| [item.key, item.band] }).to eq([['board:1:crawl', :failed]])
  end

  it 'keeps one item per source file (whatever its LT2/LT4/phase spelling): a board item beats a session item' do
    session = source_for(:data_fix_sessions, { key: 'session:x', band: :notice, since: now - 10.days,
                                               subject: { file_path: 'crawler/data/results.new/262/meet-lt4.json' } })
    board = source_for(:board_rows, { key: 'board:9:resume_review', band: :review, since: now,
                                      subject: { file_path: Rails.root.join('crawler/data/results.new/262/meet.json').to_s } })
    other = source_for(:other, { key: 'other', band: :notice, subject: { file_path: 'crawler/data/results.new/262/else.json' } })
    items = described_class.new(sources: [session, board, other]).call(context).items
    expect(items.map(&:key)).to eq(%w[board:9:resume_review other])
  end

  it 'turns a raising source into a single band-1 item' do
    broken = Class.new(Inbox::Source) do
      def self.key = :broken
      def self.name = 'BrokenSource'
      def items(_context) = raise(ArgumentError, 'kaboom')
    end
    ok = source_for(:a, { key: 'fine', band: :review })
    items = described_class.new(sources: [ok, broken]).call(context).items
    expect(items.map(&:key)).to eq(%w[inbox:broken:failed fine])
    expect(items.first.band).to eq(:failed)
    expect(items.first.title).to include('kaboom')
  end

  it 'skips the sources disabled for the context (and contains a raising enabled?)' do
    disabled = Class.new(source_for(:off, { key: 'off', band: :review })) { def self.enabled?(_context) = false }
    raising = Class.new(source_for(:bad, { key: 'bad', band: :review })) { def self.enabled?(_context) = raise('nope') }
    expect(described_class.new(sources: [disabled, raising]).call(context).items.map(&:key)).to eq(%w[inbox:bad:failed])
  end

  it 'shows 25 items at most and counts the rest per source' do
    many = source_for(:many, *Array.new(30) { |i| { key: "m#{i}", band: :review, since: now - i.minutes } })
    few = source_for(:few, *Array.new(2) { |i| { key: "f#{i}", band: :notice } })
    result = described_class.new(sources: [many, few]).call(context)
    expect(result.items.size).to eq(25)
    expect(result.items.map(&:source).uniq).to eq([:many])
    expect(result.hidden).to eq(many: 5, few: 2)
    expect(result.total).to eq(32)
  end

  describe '.canonical_file_path' do
    it 'drops the phase, .json and -lt4 suffixes' do
      base = Rails.root.join('x/meet').to_s
      %w[x/meet.json x/meet-lt4.json x/meet-lt4-phase3.json].each do |path|
        expect(described_class.canonical_file_path(path)).to eq(base)
      end
      expect(described_class.canonical_file_path(nil)).to be_nil
    end
  end
end
