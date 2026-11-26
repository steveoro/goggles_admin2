# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::Registry do
  around(:each) do |example|
    saved = described_class.keys.zip(described_class.sources)
    example.run
  ensure
    described_class.clear!
    saved.each { |key, klass| described_class.register(klass, key:) }
  end

  it 'registers the v1 sources in order (config/initializers/inbox.rb)' do
    expect(described_class.keys).to eq(%i[blockers failed_jobs pending_sql board_rows unmatched_sources data_fix_sessions fin_change fin_notice
                                          drift health ready_to_commit needs_review prepare_failed extraction_gave_up automation_paused])
  end

  it 'replaces a source in place, keeping its position (phase 07: :pending_sql)' do
    replacement = Class.new(Inbox::Source)
    described_class.replace(:pending_sql, replacement)
    expect(described_class.keys.index(:pending_sql)).to eq(2)
    expect(described_class.sources[2]).to eq(replacement)
    expect(described_class.key_for(replacement)).to eq(:pending_sql)
  end

  it 'is idempotent when the same key is registered again (code reloads)' do
    expect { described_class.register(Drift::InboxSource) }.not_to(change { described_class.sources.size })
  end
end
