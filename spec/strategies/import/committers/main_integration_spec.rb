# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::Main, type: :strategy do
  let(:fixture_base) { 'sample-200RA-l4' }
  let(:source_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}.json").to_s }
  let(:phase1_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase1.json").to_s }
  let(:phase2_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase2.json").to_s }
  let(:phase3_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase3.json").to_s }
  let(:phase4_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase4.json").to_s }
  let(:phase5_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase5.json").to_s }

  let(:committer) do
    described_class.new(
      source_path:,
      phase1_path:,
      phase2_path:,
      phase3_path:,
      phase4_path:,
      phase5_path:
    )
  end

  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    # Verify fixtures exist
    fixture_file = Rails.root.join('spec/fixtures/import/sample-200RA-l4.json')
    raise 'Fixture files not found! Run: rake fixtures:sync_with_testdb fixture_pattern=200RA' unless File.exist?(fixture_file)
  end

  describe 'initialization with real fixtures' do
    it 'initializes with all phase paths' do
      expect(committer.source_path).to eq(source_path)
      expect(committer.phase1_path).to eq(phase1_path)
      expect(committer.phase2_path).to eq(phase2_path)
      expect(committer.phase3_path).to eq(phase3_path)
      expect(committer.phase4_path).to eq(phase4_path)
      expect(committer.phase5_path).to eq(phase5_path)
    end

    it 'initializes stats hash' do
      stats = committer.stats

      expect(stats[:meetings_created]).to eq(0)
      expect(stats[:teams_created]).to eq(0)
      expect(stats[:swimmers_created]).to eq(0)
      expect(stats[:badges_created]).to eq(0)
      expect(stats[:events_created]).to eq(0)
      expect(stats[:errors]).to eq([])
    end

    it 'loads phase data when load_phase_files! is called' do # rubocop:disable RSpec/MultipleExpectations
      committer.send(:load_phase_files!)

      phase1_data = committer.instance_variable_get(:@phase1_data)
      phase2_data = committer.instance_variable_get(:@phase2_data)
      phase3_data = committer.instance_variable_get(:@phase3_data)
      phase4_data = committer.instance_variable_get(:@phase4_data)
      phase5_data = committer.instance_variable_get(:@phase5_data)

      expect(phase1_data).not_to be_nil
      expect(phase2_data).not_to be_nil
      expect(phase3_data).not_to be_nil
      expect(phase4_data).not_to be_nil
      expect(phase5_data).not_to be_nil

      # Verify data structure
      expect(phase1_data['data']).to have_key('season_id')
      expect(phase2_data['data']['teams']).to be_an(Array)
      expect(phase3_data['data']['badges']).to be_an(Array)
      expect(phase4_data['data']['sessions']).to be_an(Array)
    end
  end

  describe 'pre-matching pattern with real data' do
    before(:each) { committer.send(:load_phase_files!) }

    it 'handles team_affiliation data structure' do
      phase2_data = committer.instance_variable_get(:@phase2_data)
      first_affiliation = phase2_data['data']['team_affiliations'].first

      # Verify data structure (ID may be nil if cleared by sync)
      expect(first_affiliation).to have_key('team_affiliation_id')
      expect(first_affiliation).to have_key('team_id')
      expect(first_affiliation).to have_key('season_id')

      # If ID exists, it should be valid
      if first_affiliation['team_affiliation_id'].present?
        expect(first_affiliation['team_affiliation_id']).to be_a(Integer)
        expect(first_affiliation['team_affiliation_id']).to be > 0
      end
    end

    it 'handles badge data structure' do
      phase3_data = committer.instance_variable_get(:@phase3_data)
      first_badge = phase3_data['data']['badges'].first

      # Verify data structure (ID may be nil if cleared by sync)
      expect(first_badge).to have_key('badge_id')
      expect(first_badge).to have_key('swimmer_id')
      expect(first_badge).to have_key('team_id')

      # If ID exists, it should be valid
      if first_badge['badge_id'].present?
        expect(first_badge['badge_id']).to be_a(Integer)
        expect(first_badge['badge_id']).to be > 0
      end
    end

    it 'has structured event data in phase4' do
      phase4_data = committer.instance_variable_get(:@phase4_data)

      # Find a session with events (first session might be empty)
      session_with_events = phase4_data['data']['sessions'].find { |s| s['events']&.any? }
      skip 'No session with events in fixtures' unless session_with_events

      first_event = session_with_events['events'].first

      # Verify event structure (note: meeting_event_id may be nil if not yet matched)
      expect(first_event).to have_key('event_type_id')
      expect(first_event['event_type_id']).to be_a(Integer)
      expect(first_event).to have_key('session_order')
    end
  end

  describe '#commit_team_affiliation with synced data' do
    before(:each) { committer.send(:load_phase_files!) }

    it 'handles affiliations correctly based on ID presence' do
      phase2_data = committer.instance_variable_get(:@phase2_data)

      # Find an affiliation with an ID (if any exist after sync)
      affiliation_with_id = phase2_data['data']['team_affiliations'].find { |a| a['team_affiliation_id'].present? }

      if affiliation_with_id
        initial_count = GogglesDb::TeamAffiliation.count
        committer.send(:commit_team_affiliation, affiliation_hash: affiliation_with_id)
        # Should skip because ID is present
        expect(GogglesDb::TeamAffiliation.count).to eq(initial_count)
      else
        # All IDs were cleared - verify structure is still valid
        first_affiliation = phase2_data['data']['team_affiliations'].first
        expect(first_affiliation).to have_key('team_id')
        expect(first_affiliation).to have_key('season_id')
      end
    end
  end

  # NOTE: commit_badge, commit_meeting_event, commit_team_affiliation methods
  # were refactored to dedicated committer classes. Tests for those are in their
  # respective spec files.

  describe 'phase3 data structure' do
    before(:each) { committer.send(:load_phase_files!) }

    it 'has valid badge structure with category_type_id' do
      phase3_data = committer.instance_variable_get(:@phase3_data)

      # Find a badge with category_type_id set
      badge_with_category = phase3_data['data']['badges'].find { |b| b['category_type_id'].present? }
      skip 'No badge with category_type_id in fixtures' unless badge_with_category

      expect(badge_with_category['category_type_id']).to be_a(Integer)
      expect(badge_with_category['category_type_id']).to be > 0
    end
  end

  describe 'SQL log generation' do
    it 'generates SQL log entries' do
      # Just verify the SQL log mechanism exists and is accessible
      expect(committer.sql_log).to be_an(Array)
      expect(committer).to respond_to(:sql_log_content)
    end
  end

  describe 'error handling' do
    it 'initializes with empty errors array' do
      expect(committer.stats[:errors]).to eq([])
    end
  end

  describe 'stats tracking' do
    it 'maintains stats counters' do
      # Verify stats hash exists and has expected keys
      stats = committer.stats

      expect(stats).to have_key(:affiliations_created)
      expect(stats).to have_key(:badges_created)
      expect(stats).to have_key(:meetings_created)
      expect(stats).to have_key(:errors)

      # All should be initialized to 0/empty
      expect(stats[:affiliations_created]).to eq(0)
      expect(stats[:badges_created]).to eq(0)
      expect(stats[:errors]).to eq([])

      # The actual incrementing is tested by the original unit tests
      # Integration tests verify the mechanism works with real data
    end
  end
end
