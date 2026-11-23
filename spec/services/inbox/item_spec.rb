# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::Item do
  let(:action) { Inbox::Action.new(label: 'Open', path: '/somewhere') }

  def build(**overrides)
    described_class.new(key: 'k', source: :test, kind: :thing, band: :review, title: 'Title', action:, **overrides)
  end

  it 'needs exactly one Inbox::Action' do
    expect { build(action: nil) }.to raise_error(ArgumentError, /Inbox::Action/)
    expect { build(action: { label: 'x', path: '/x' }) }.to raise_error(ArgumentError)
    expect { build(secondary_action: 'nope') }.to raise_error(ArgumentError)
  end

  it 'accepts a band by name or by rank, and refuses an unknown one' do
    expect(build(band: 2).band).to eq(:push)
    expect(build(band: 'notice').band_rank).to eq(5)
    expect { build(band: :urgent) }.to raise_error(ArgumentError)
  end

  it 'has sensible defaults' do
    item = build
    expect(item.count).to eq(1)
    expect(item.subject).to eq({})
    expect(item.since).to be_within(5.seconds).of(Time.current)
    expect(item.secondary_action).to be_nil
  end

  describe Inbox::Action do
    it 'supports GET, POST and DELETE only, with a label and a path' do
      expect(described_class.new(label: 'Go', path: '/x', http_method: 'POST').http_method).to eq(:post)
      expect { described_class.new(label: 'Go', path: '/x', http_method: :patch) }.to raise_error(ArgumentError)
      expect { described_class.new(label: '', path: '/x') }.to raise_error(ArgumentError)
    end

    it 'tells a full URL (docs) from an app path' do
      expect(described_class.new(label: 'Docs', path: 'https://example.com/docs')).to be_external
      expect(described_class.new(label: 'Go', path: '/x')).not_to be_external
    end
  end
end
