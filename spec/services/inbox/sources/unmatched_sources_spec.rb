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

  it 'resumes the review step, opens the Phase 1 review or the Sources Manifests tab' do
    expect(items['unmatched:in-rev'].action.path).to start_with('/data_fix/review_teams?')
    expect(items['unmatched:in-rev'].band).to eq(:review)
    expect(items['unmatched:src'].action.path).to eq("/data_fix/review_sessions?file_path=#{CGI.escape('/d/262/src-lt4.json')}")
    expect(items['unmatched:pdf'].action.path).to eq('/sources/manifests?season_id=262')
    expect(items['unmatched:pdf'].band).to eq(:acquire)
  end

  it 'leaves a source prepared from the Sources page (any pipeline state) to the pipeline sources (phase 15)' do
    prepared = unmatched('in-rev', 'in_review', review_path: '/d/262/in-rev.json', phase: 2).merge('pipeline' => { 'state' => 'needs_review' })
    preparing = unmatched('src', 'source', review_path: '/d/262/src-lt4.json').merge('pipeline' => { 'state' => 'preparing' })
    queued = unmatched('queued', 'source', review_path: '/d/262/queued-lt4.json').merge('pipeline' => { 'state' => 'prepare_queued' })
    other = board_summary(unmatched: [prepared, preparing, queued])
    expect(other.unmatched_sources.map(&:pipeline_state)).to eq(%i[needs_review preparing prepare_queued])
    expect(other.unmatched_sources.map(&:preparing?)).to eq([false, true, true])
    expect(described_class.new.items(inbox_context(board_snapshot: other))).to be_empty
  end

  # 0.10.102
  it 'emits the pending sources whose FIN id is on no board row, with their own key and titles' do
    payload = { 'season_id' => 262, 'built_at' => '2026-11-23T09:00:00+01:00', 'rows' => [], 'unmatched_sources' => [],
                'off_board_sources' => [unmatched('lignano', 'source', review_path: '/d/262/lignano.json').merge('fin_event_id' => '150244'),
                                        unmatched('sql', 'sql', paths: ['/d/262/0002-x-lt4.sql']).merge('fin_event_id' => '150099')] }
    summary = SeasonBoard::Snapshot::Summary.from_payload(payload, stored: true, taken_at: Time.current)
    found = I18n.with_locale(:en) { described_class.new.items(inbox_context(board_snapshot: summary)) }
    expect(found.map(&:key)).to eq(['off_board:150244:lignano'])
    expect(found.first).to have_attributes(title: 'Source of FIN 150244, not on the board: lignano', band: :review)
    expect(found.first.detail).to include('FIN 150244 is on no Season board row')
    expect(found.first.action.path).to eq("/data_fix/review_sessions?file_path=#{CGI.escape('/d/262/lignano.json')}")
  end

  it 'lists more on the Sources results tab' do
    expect(described_class.more_path).to eq('/sources/results')
  end
end
