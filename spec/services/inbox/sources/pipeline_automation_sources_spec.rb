# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

# Phase 10 inbox sources: ready to commit, needs review, prepare failed, extraction given up, automation paused.
RSpec.describe 'Pipeline automation inbox sources' do # rubocop:disable RSpec/DescribeClass
  include InboxSummaryFixtures

  around(:each) { |example| I18n.with_locale(:en) { example.run } }

  def row(fin_event_id, state, kind, detail: {}, **options)
    board_row_payload(fin_event_id, state, kind, **options).merge('state_detail' => detail.stringify_keys)
  end

  let(:rows) do
    [
      row('1', :ready_to_commit, :commit, detail: { new_teams: 2, new_swimmers: 37 }, name: 'Trofeo Pronto', file_path: '/d/262/a.json'),
      row('2', :needs_review, :resume_review, detail: { step: 3, count: 4, blocked: false }, name: 'Trofeo Review', file_path: '/d/262/b.json',
                                              phase: 3, filter_state: 'review'),
      row('3', :prepare_failed, :prepare, detail: { phase: 4, message: 'solver exploded' }, name: 'Trofeo Rotto', file_path: '/d/262/c.json'),
      row('4', :ready_to_commit, :commit, name: 'Busy one', busy: true, locked: true, file_path: '/d/262/d.json'),
      row('5', :manifest_pending, :extract_manifest, name: 'Manifest', pdf_path: '/m/262/manifest-e.pdf')
    ]
  end
  let(:context) { inbox_context(board_snapshot: board_summary(rows:)) }

  it 'ReadyToCommit: "Ready to commit · +2 teams, +37 swimmers" opening the commit summary (never committing)' do
    items = Inbox::Sources::ReadyToCommit.new.items(context)
    expect(items.size).to eq(1) # (the locked row is skipped)
    item = items.first
    expect(item).to have_attributes(key: 'board:1:commit', kind: :ready_to_commit, band: :review, subject: hash_including(file_path: '/d/262/a.json'))
    expect(item.title).to eq('Trofeo Pronto: Ready to commit · +2 teams, +37 swimmers')
    expect(item.action).to have_attributes(label: 'Commit', http_method: :get, path: '/data_fix/commit_summary?file_path=%2Fd%2F262%2Fa.json')
  end

  it 'NeedsReview: "Needs review at step 3 · 4 issues" opening the step with the review filter' do
    item = Inbox::Sources::NeedsReview.new.items(context).sole
    expect(item.title).to eq('Trofeo Review: Needs review at step 3 · 4 issues')
    expect(item.action.label).to eq('Review step 3')
    expect(item.action.path).to start_with('/data_fix/review_swimmers?').and include('filter_state=review', 'phase3_v2=1')
  end

  it 'PrepareFailed: "Preparation failed at step 4: ..." with a Retry POST to the board' do
    item = Inbox::Sources::PrepareFailed.new.items(context).sole
    expect(item).to have_attributes(band: :failed, title: 'Trofeo Rotto: Preparation failed at step 4: solver exploded')
    expect(item.action).to have_attributes(label: 'Retry', http_method: :post, path: '/season_board/prepare', params: { fin_event_id: '3' })
  end

  # 0.10.99: a prepare merely queued (busy, not locked) no longer hides a review / commit item; a POST (Retry) still waits.
  it 'keeps the needs-review and ready-to-commit items of a busy row that is not locked, never a busy Retry' do
    queued = [
      row('6', :ready_to_commit, :commit, name: 'Queued ready', busy: true, file_path: '/d/262/f.json'),
      row('7', :needs_review, :resume_review, detail: { step: 2, count: 1 }, name: 'Queued review', busy: true, file_path: '/d/262/g.json',
                                              phase: 2, filter_state: 'review'),
      row('8', :prepare_failed, :prepare, detail: { phase: 2 }, name: 'Queued retry', busy: true, file_path: '/d/262/h.json')
    ]
    queued_context = inbox_context(board_snapshot: board_summary(rows: queued))
    expect(Inbox::Sources::ReadyToCommit.new.items(queued_context).map(&:key)).to eq(['board:6:commit'])
    expect(Inbox::Sources::NeedsReview.new.items(queued_context).map(&:key)).to eq(['board:7:resume_review'])
    expect(Inbox::Sources::PrepareFailed.new.items(queued_context)).to eq([])
  end

  it 'labels a ready-to-commit row whose checks are outdated "Checks outdated", not "step 5 · 0 issues"' do
    outdated = row('9', :needs_review, :resume_review, detail: { step: 5, count: 0, blocked: false, outdated: true }, name: 'Trofeo Vecchio',
                                                       file_path: '/d/262/i.json', phase: 5, filter_state: 'review')
    item = Inbox::Sources::NeedsReview.new.items(inbox_context(board_snapshot: board_summary(rows: [outdated]))).sole
    expect(item.title).to eq('Trofeo Vecchio: Checks outdated')
  end

  it 'BoardRows leaves the three pipeline states to their own sources' do
    keys = Inbox::Sources::BoardRows.new.items(context).map(&:key)
    expect(keys).to eq(['board:5:extract_manifest'])
  end

  describe 'ExtractionGaveUp' do
    it 'replaces the board extraction item after 3 failed automatic attempts ("Extract manually")' do
      expect(Inbox::Sources::ExtractionGaveUp.new.items(context)).to be_empty
      3.times do
        FactoryBot.create(:ops_pipeline_run, kind: 'extract', origin: 'auto', subject_key: 'manifest-e.pdf', status: 'failed', finished_at: 1.day.ago)
      end
      item = Inbox::Sources::ExtractionGaveUp.new.items(context).sole
      expect(item).to have_attributes(key: 'board:5:extract_manifest', band: :failed, kind: :extraction_gave_up)
      expect(item.action).to have_attributes(label: 'Extract manually', http_method: :post, path: '/season_board/extract')

      merged = Inbox::Builder.new(sources: [Inbox::Sources::BoardRows, Inbox::Sources::ExtractionGaveUp]).call(context).items
      expect(merged.map(&:kind)).to eq([:extraction_gave_up])
    end
  end

  describe 'AutomationPaused' do
    it 'shows one notice while the master switch is off, opening the switches' do
      expect(Inbox::Sources::AutomationPaused.new.items(context)).to be_empty
      DataFix::Automation.store!(:enabled, false)
      item = Inbox::Sources::AutomationPaused.new.items(context).sole
      expect(item).to have_attributes(key: 'automation:paused', band: :notice, title: 'Automation paused')
      expect(item.action.path).to eq('/#dashboard-system')
    end

    it 'shows it with ADMIN2_AUTOMATION=0, and not for a sub-switch turned off on purpose' do
      DataFix::Automation.store!(:auto_extract, false)
      expect(Inbox::Sources::AutomationPaused.new.items(context)).to be_empty
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect(Inbox::Sources::AutomationPaused.new.items(context).sole.detail).to include('ADMIN2_AUTOMATION=0')
    end
  end

  it 'lets the board items win the de-duplication by file path over an idle Data-Fix session' do
    session = Inbox::Item.new(key: 'session:/d/262/a-lt4.json', source: :data_fix_sessions, kind: :idle_session, band: :notice, title: 'Idle',
                              subject: { file_path: '/d/262/a-lt4.json' }, action: Inbox::Action.new(label: 'Resume', path: '/x'))
    idle = Class.new(Inbox::Source) do
      define_singleton_method(:key) { :data_fix_sessions }
      define_method(:items) { |_context| [session] }
    end
    items = Inbox::Builder.new(sources: [idle, Inbox::Sources::ReadyToCommit]).call(context).items
    expect(items.map(&:kind)).to eq([:ready_to_commit])
  end

  # Phase 15: a non-FIN source prepared from the Sources page (an unmatched source of the board summary).
  describe 'prepared non-FIN sources' do
    def unmatched(base, state, detail = {})
      { 'base' => base, 'bases' => [base], 'pending' => 'in_review', 'review_path' => "/d/262/#{base}-lt4.json", 'phase' => 5,
        'paths' => [], 'pipeline' => { 'state' => state.to_s, 'detail' => detail.stringify_keys } }
    end

    let(:context) do
      inbox_context(board_snapshot: board_summary(unmatched: [
                                                    unmatched('microplus-riccione', :ready_to_commit, new_teams: 1),
                                                    unmatched('ficr-brescia', :needs_review, step: 2, count: 3),
                                                    unmatched('goandswim-x', :prepare_failed, phase: 3, message: 'boom'),
                                                    unmatched('busy-one', :preparing),
                                                    unmatched('queued-retry', :prepare_queued)
                                                  ]))
    end

    it 'ReadyToCommit opens their commit summary' do
      item = Inbox::Sources::ReadyToCommit.new.items(context).sole
      expect(item).to have_attributes(key: 'unmatched:microplus-riccione:commit', band: :review,
                                      title: 'microplus-riccione: Ready to commit · +1 team',
                                      subject: { file_path: '/d/262/microplus-riccione-lt4.json', season_id: 262 })
      expect(item.action.path).to eq("/data_fix/commit_summary?file_path=#{CGI.escape('/d/262/microplus-riccione-lt4.json')}")
    end

    it 'NeedsReview opens the step with the review filter' do
      item = Inbox::Sources::NeedsReview.new.items(context).sole
      expect(item.title).to eq('ficr-brescia: Needs review at step 2 · 3 issues')
      expect(item.action.path).to start_with('/data_fix/review_teams?').and include('filter_state=review')
    end

    it 'PrepareFailed retries through the Sources "Prepare" (a POST, never a commit)' do
      item = Inbox::Sources::PrepareFailed.new.items(context).sole
      expect(item).to have_attributes(band: :failed, title: 'goandswim-x: Preparation failed at step 3: boom')
      expect(item.action).to have_attributes(http_method: :post, path: '/sources/prepare',
                                             params: { path: '/d/262/goandswim-x-lt4.json', season_id: 262 })
    end
  end
end
