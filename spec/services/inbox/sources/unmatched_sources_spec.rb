# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::UnmatchedSources do
  include InboxSummaryFixtures

  def unmatched(base, pending, review_path: nil, phase: nil, paths: [])
    { 'base' => base, 'bases' => [base], 'pending' => pending, 'review_path' => review_path, 'phase' => phase, 'paths' => paths }
  end

  let(:summary) do
    board_summary(unmatched: [
                    unmatched('in-rev', 'in_review', review_path: '/d/262/in-rev.json', phase: 2),
                    unmatched('src', 'source', review_path: '/d/262/src-lt4.json'),
                    unmatched('pdf', 'manifest', paths: ['/d/manifests/262/manifest-pdf.pdf']),
                    unmatched('sql', 'sql', paths: ['/d/262/0001-sql-lt4.sql'])
                  ])
  end
  let(:items) { described_class.new.items(inbox_context(board_snapshot: summary)).index_by(&:key) }

  it 'emits the in-review, source and manifest entries (the SQL ones are left to PendingSql)' do
    expect(items.keys).to contain_exactly('unmatched:in-rev', 'unmatched:src', 'unmatched:pdf')
  end

  it 'resumes the review step, opens the Phase 1 review or the result files page' do
    expect(items['unmatched:in-rev'].action.path).to start_with('/data_fix/review_teams?')
    expect(items['unmatched:in-rev'].band).to eq(:review)
    expect(items['unmatched:src'].action.path).to eq("/data_fix/review_sessions?file_path=#{CGI.escape('/d/262/src-lt4.json')}")
    expect(items['unmatched:pdf'].action.path).to eq('/pull/result_files')
    expect(items['unmatched:pdf'].band).to eq(:acquire)
  end
end
