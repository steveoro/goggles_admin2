# frozen_string_literal: true

require 'rails_helper'

# (The full state table, with real disk fixtures, is in builder_spec.rb)
RSpec.describe SeasonBoard::StateResolver do
  subject(:resolver) { described_class.new(today: Date.new(2026, 11, 12)) }

  let(:url) { 'https://www.federnuoto.it/x.html#/risultati/150091:a.html' }

  # links: calendar, meeting, disk
  def facts(info: '', url: self.url, date: '08/11', **links)
    described_class::Facts.new(
      row: { 'info' => info, 'url' => url }, fin_event_id: FINEventId.parse(url),
      row_date: SeasonBoard::RowDate.parse(date, '2026'), calendar: nil, meeting: nil, disk: nil, **links
    )
  end

  def meeting(results_acquired: false, mir_count: 0, cancelled: false)
    SeasonBoard::DbIndex::MeetingInfo.new(id: 5, description: 'M', code: 'm', header_date: nil, cancelled:,
                                          results_acquired:, manifest: true, mir_count:, mrr_count: 0)
  end

  ['ANNULLATA', 'gara annullata', 'Rinviata a data da destinarsi', 'RINVIO', 'Cancelled'].each do |info|
    it "detects cancellation from the info text #{info.inspect}" do
      expect(resolver.call(facts(info:)).state).to eq(:cancelled)
    end
  end

  it 'does not treat a blank or unrelated info text as cancelled' do
    expect(resolver.call(facts(info: 'Risultati')).state).to eq(:link_not_crawled)
  end

  it 'always includes the FIN id in the action params' do
    outcome = resolver.call(facts)
    expect(outcome.next_action).to eq(SeasonBoard::NextAction.new(kind: :crawl, params: { fin_event_id: '150091', url: }))
    expect(outcome.next_action[:url]).to eq(url)
  end

  it 'suggests :check_results only once the last date is past' do
    expect(resolver.call(facts(meeting: meeting, date: '11-12/11')).next_action).to be_nil
    outcome = resolver.call(facts(meeting: meeting, date: '10-11/11'))
    expect(outcome.state).to eq(:structure_committed)
    expect(outcome.detail).to eq(past: true)
    expect(outcome.next_action.params).to eq(fin_event_id: '150091', url:, meeting_id: 5)
  end

  it 'never suggests :check_results for a meeting with results' do
    expect(resolver.call(facts(meeting: meeting(mir_count: 1))).state).to eq(:committed_with_results)
    expect(resolver.call(facts(meeting: meeting(results_acquired: true))).next_action).to be_nil
  end

  it 'cancels on a cancelled meeting' do
    expect(resolver.call(facts(meeting: meeting(cancelled: true))).state).to eq(:cancelled)
  end

  describe 'pipeline states (phase 10)' do
    let(:source) do
      SeasonBoard::DiskIndex::Source.new(base: 'm', lt2_path: '/d/m.json', lt4_path: '/d/m-lt4.json', has_results: true, meeting_only: false,
                                         phase: 3, phase_paths: { 3 => '/d/m-lt4-phase3.json' }, mtime: Time.current)
    end
    let(:disk) do
      SeasonBoard::DiskIndex::Entry.new('150091').tap { |entry| entry.sources << source }
    end

    # PipelineIndex::Facts with the given overrides (defaults: fresh, clean verdicts, nothing failed).
    def pipeline(**overrides)
      SeasonBoard::PipelineIndex::Facts.new(
        source_id: 1, base: 'm', source_path: '/d/m-lt4.json', stage: 'ready_to_commit', stage_reason: nil, review_phase: nil, review_count: 0,
        new_teams: 2, new_swimmers: 37, held: false, preparing: false, verdict_count: 5, fresh: true, edited_recorded: false, stale_phases: [],
        db_behind: false, collision_bases: [], last_run: nil, failed: false, source_changed: false, failed_phase: nil, failed_message: nil,
        highest_phase: 3, **overrides
      )
    end

    it ':ready_to_commit (every verdict clean and fresh) wins over :in_review, with a :commit action' do
      outcome = resolver.call(facts(disk:, pipeline: pipeline))
      expect(outcome).to have_attributes(state: :ready_to_commit, detail: { new_teams: 2, new_swimmers: 37 })
      expect(outcome.next_action).to have_attributes(kind: :commit, params: { fin_event_id: '150091', file_path: '/d/m.json' })
    end

    it ':needs_review resumes at the review step with the review filter, and a stale "ready" needs review too' do
      outcome = resolver.call(facts(disk:, pipeline: pipeline(stage: 'needs_review', review_phase: 2, review_count: 4)))
      expect(outcome).to have_attributes(state: :needs_review, detail: { step: 2, count: 4, blocked: false })
      expect(outcome.next_action.params).to include(phase: 2, filter_state: 'review', file_path: '/d/m.json')
      expect(resolver.call(facts(disk:, pipeline: pipeline(fresh: false))).state).to eq(:needs_review)
      expect(resolver.call(facts(disk:, pipeline: pipeline(stage: 'blocked', review_phase: 5))).detail).to include(blocked: true, step: 5)
    end

    it ':prepare_failed (source unchanged) wins over the review states, with a :prepare (Retry) action' do
      outcome = resolver.call(facts(disk:, pipeline: pipeline(stage: 'failed', failed: true, failed_phase: 4, failed_message: 'boom')))
      expect(outcome).to have_attributes(state: :prepare_failed, detail: { phase: 4, message: 'boom' })
      expect(outcome.next_action.kind).to eq(:prepare)
      changed = pipeline(stage: 'failed', failed: true, source_changed: true)
      expect(resolver.call(facts(disk:, pipeline: changed)).state).to eq(:in_review)
    end

    it 'loses to :sql_pending and :cancelled' do
      disk.sql_new_paths << '/d/0001-m-lt4.sql'
      expect(resolver.call(facts(disk:, pipeline: pipeline)).state).to eq(:sql_pending)
      expect(resolver.call(facts(info: 'ANNULLATA', disk:, pipeline: pipeline)).state).to eq(:cancelled)
    end

    it 'wins over :results_ready, and is ignored while a prepare runs (busy overlay)' do
      results = SeasonBoard::DiskIndex::Source.new(base: 'm', lt2_path: '/d/m.json', lt4_path: nil, has_results: true, meeting_only: false,
                                                   phase: nil, phase_paths: {}, mtime: Time.current)
      entry = SeasonBoard::DiskIndex::Entry.new('150091').tap { |e| e.sources << results }
      expect(resolver.call(facts(disk: entry, pipeline: pipeline)).state).to eq(:ready_to_commit)
      expect(resolver.call(facts(disk: entry, pipeline: pipeline(preparing: true))).state).to eq(:results_ready)
    end

    it 'keeps the former states without pipeline facts (pre-09 phase files stay :in_review)' do
      expect(resolver.call(facts(disk:)).state).to eq(:in_review)
    end
  end

  it 'returns :not_linked (no action) without URL' do
    outcome = resolver.call(facts(url: ''))
    expect(outcome).to have_attributes(state: :not_linked, detail: {}, next_action: nil)
  end
end
