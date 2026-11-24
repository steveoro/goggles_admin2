# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::BoardRows do
  include InboxSummaryFixtures

  let(:rows) do
    [
      board_row_payload('1', :link_not_crawled, :crawl, url: 'https://fin.example/1'),
      board_row_payload('2', :results_ready, :review_results, file_path: '/d/262/r.json'),
      board_row_payload('3', :in_review, :resume_review, file_path: '/d/262/p.json', phase: 3, last_date: '2026-10-01'),
      board_row_payload('4', :manifest_pending, :extract_manifest, pdf_path: '/m.pdf'),
      board_row_payload('5', :archived_unlinked, :link, bases: ['b']),
      board_row_payload('6', :sql_pending, :push, sql_path: '/s.sql'),
      board_row_payload('7', :link_not_crawled, :crawl, busy: true),
      board_row_payload('8', :committed_with_results)
    ]
  end
  let(:items) { described_class.new.items(inbox_context(board_snapshot: board_summary(rows:))) }

  it 'emits one item per row with a next action, skipping busy rows and pushes' do
    expect(items.map(&:key)).to contain_exactly('board:1:crawl', 'board:2:review_results', 'board:3:resume_review',
                                                'board:4:extract_manifest', 'board:5:link')
  end

  it 'puts the reviews in the review band and the rest in the acquire band' do
    expect(items.to_h { |item| [item.kind, item.band] })
      .to eq(crawl: :acquire, review_results: :review, resume_review: :review, extract_manifest: :acquire, link: :acquire)
  end

  it 'builds the targets with SeasonBoard::ActionPaths' do
    by_kind = items.index_by(&:kind)
    expect(by_kind[:crawl].action).to have_attributes(http_method: :post, path: '/season_board/crawl', params: { fin_event_id: '1' })
    expect(by_kind[:extract_manifest].action).to have_attributes(http_method: :post, path: '/season_board/extract')
    expect(by_kind[:resume_review].action.path).to start_with('/data_fix/review_swimmers?')
    expect(by_kind[:link].action.path).to eq('/season_board#season-board-row-5')
    expect(by_kind[:review_results].subject).to eq(fin_event_id: '2', file_path: '/d/262/r.json', season_id: 262)
  end

  it 'waits since the meeting date (older meetings first)' do
    expect(items.min_by(&:since).key).to eq('board:3:resume_review')
  end

  it 'emits nothing without a board summary' do
    expect(described_class.new.items(inbox_context)).to eq([])
  end
end
