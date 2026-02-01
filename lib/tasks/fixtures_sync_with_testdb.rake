# frozen_string_literal: true

require 'goggles_db'

# rubocop:disable Rake/MethodDefinitionInTask, Metrics/CyclomaticComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength
namespace :fixtures do
  desc <<~DESC
    Synchronizes phase fixture files with the anonymized test database.

    ⚠️  CRITICAL: Must run in test environment (RAILS_ENV=test)

    For each entity ID found in the fixture files:
    - If the ID exists in the test DB: replaces fixture attributes with DB values (anonymized)
    - If the ID does NOT exist: clears the ID (will be created as new)

    This ensures fixtures work correctly with the anonymized test database dump.

    Options: [fixture_dir=<spec/fixtures/import>]
             [fixture_pattern=<200RA>]
             [dry_run=<true|false>]

      - fixture_dir: directory containing phase fixture files (default: spec/fixtures/import)
      - fixture_pattern: filename pattern to match (default: 200RA, matches *200RA*-phase*.json)
      - dry_run: if true, shows what would change without writing files (default: false)

    Examples:
      RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb
      RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb fixture_pattern=200RA dry_run=true
      RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb fixture_pattern=100SL

  DESC
  task sync_with_testdb: :environment do
    # CRITICAL: Must run in test environment to access test database
    unless Rails.env.test?
      puts "\r\n⚠️  ERROR: This task MUST run in test environment!"
      puts 'Usage: RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb'
      exit 1
    end

    puts "\r\n*** Synchronize Phase Fixtures with Test Database ***"
    puts "Environment: #{Rails.env} ✓"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    puts '-' * 80

    fixture_dir = ENV.fetch('fixture_dir', 'spec/fixtures/import')
    fixture_pattern = ENV.fetch('fixture_pattern', '200RA')
    dry_run = ENV.fetch('dry_run', 'false').downcase == 'true'

    fixture_path = Rails.root.join(fixture_dir)
    raise "Fixture directory not found: #{fixture_path}" unless File.directory?(fixture_path)

    # Find all phase files matching pattern (excluding symlinks)
    all_files = Dir.glob(File.join(fixture_path, '*-phase*.json'))
    files = all_files.reject { |f| File.symlink?(f) }.select { |f| File.basename(f).include?(fixture_pattern) }

    if files.empty?
      puts "No fixture files found matching pattern: *#{fixture_pattern}*-phase*.json"
      puts "Searched in: #{fixture_path}"
      exit 0
    end

    puts "Found #{files.count} phase files to process:"
    files.each { |f| puts "  - #{File.basename(f)}" }
    puts "\r\nMode: #{dry_run ? 'DRY RUN (no changes will be written)' : 'WRITE MODE'}"
    puts '-' * 80

    stats = {
      total_entities: 0,
      found_in_db: 0,
      not_found_in_db: 0,
      updated: 0,
      cleared: 0
    }

    files.each do |file_path|
      process_phase_file(file_path, dry_run, stats)
    end

    puts "\r\n#{'=' * 80}"
    puts 'SUMMARY:'
    puts "  Total entities processed: #{stats[:total_entities]}"
    puts "  Found in DB (updated):    #{stats[:found_in_db]} (#{stats[:updated]} changed)"
    puts "  Not found (ID cleared):   #{stats[:not_found_in_db]} (#{stats[:cleared]} cleared)"
    puts '=' * 80
    puts dry_run ? "\r\nDRY RUN complete - no files were modified." : "\r\nSync complete!"
  end

  # Process a single phase file
  def process_phase_file(file_path, dry_run, stats)
    filename = File.basename(file_path)
    puts "\r\n--- Processing: #{filename} ---"

    data = JSON.parse(File.read(file_path))
    modified = false

    phase_num = extract_phase_number(filename)

    case phase_num
    when 1
      modified = process_phase1(data, stats)
    when 2
      modified = process_phase2(data, stats)
    when 3
      modified = process_phase3(data, stats)
    when 4
      modified = process_phase4(data, stats)
    when 5
      modified = process_phase5(data, stats)
    else
      puts "  Skipping - unknown phase number: #{phase_num}"
      return
    end

    if modified && !dry_run
      File.write(file_path, JSON.pretty_generate(data))
      puts '  ✓ File updated'
    elsif modified && dry_run
      puts '  [DRY RUN] Would update file'
    else
      puts '  No changes needed'
    end
  end

  def extract_phase_number(filename)
    filename[/phase(\d+)/, 1]&.to_i
  end

  # Phase 1: Meeting, MeetingSessions
  def process_phase1(data, stats)
    modified = false
    phase_data = data['data']

    # Meeting
    if phase_data['meeting'] && phase_data['meeting']['meeting_id']
      meeting_id = phase_data['meeting']['meeting_id']
      stats[:total_entities] += 1

      meeting = GogglesDb::Meeting.find_by(id: meeting_id)
      if meeting
        stats[:found_in_db] += 1
        if sync_meeting!(phase_data['meeting'], meeting)
          modified = true
          stats[:updated] += 1
          puts "  Meeting ID=#{meeting_id}: synced with DB (#{meeting.description})"
        end
      else
        stats[:not_found_in_db] += 1
        phase_data['meeting']['meeting_id'] = nil
        stats[:cleared] += 1
        modified = true
        puts "  Meeting ID=#{meeting_id}: NOT FOUND - ID cleared"
      end
    end

    # Meeting Sessions
    if phase_data['meeting_sessions'].is_a?(Array)
      phase_data['meeting_sessions'].each do |session_hash|
        next unless session_hash['meeting_session_id']

        session_id = session_hash['meeting_session_id']
        stats[:total_entities] += 1

        session = GogglesDb::MeetingSession.find_by(id: session_id)
        if session
          stats[:found_in_db] += 1
          if sync_meeting_session!(session_hash, session)
            modified = true
            stats[:updated] += 1
            puts "  Session ID=#{session_id}: synced"
          end
        else
          stats[:not_found_in_db] += 1
          session_hash['meeting_session_id'] = nil
          stats[:cleared] += 1
          modified = true
          puts "  Session ID=#{session_id}: NOT FOUND - ID cleared"
        end
      end
    end

    modified
  end

  # Phase 2: Teams, TeamAffiliations
  def process_phase2(data, stats)
    modified = false
    phase_data = data['data']

    # Teams
    if phase_data['teams'].is_a?(Array)
      phase_data['teams'].each do |team_hash|
        next unless team_hash['team_id']

        team_id = team_hash['team_id']
        stats[:total_entities] += 1

        team = GogglesDb::Team.find_by(id: team_id)
        if team
          stats[:found_in_db] += 1
          if sync_team!(team_hash, team)
            modified = true
            stats[:updated] += 1
            puts "  Team ID=#{team_id}: synced (#{team.name})"
          end
        else
          stats[:not_found_in_db] += 1
          team_hash['team_id'] = nil
          stats[:cleared] += 1
          modified = true

          # Clear fuzzy_matches entirely - production DB IDs are meaningless in test context
          team_hash['fuzzy_matches'] = [] if team_hash['fuzzy_matches'].is_a?(Array) && team_hash['fuzzy_matches'].any?

          puts "  Team ID=#{team_id}: NOT FOUND - ID cleared"
        end
      end
    end

    # TeamAffiliations
    if phase_data['team_affiliations'].is_a?(Array)
      phase_data['team_affiliations'].each do |affiliation_hash|
        next unless affiliation_hash['team_affiliation_id']

        affiliation_id = affiliation_hash['team_affiliation_id']
        stats[:total_entities] += 1

        affiliation = GogglesDb::TeamAffiliation.find_by(id: affiliation_id) ||
                      GogglesDb::TeamAffiliation.where(team_id: affiliation_hash['team_id'], season_id: affiliation_hash['season_id']).first
        if affiliation
          stats[:found_in_db] += 1
          if sync_team_affiliation!(affiliation_hash, affiliation)
            modified = true
            stats[:updated] += 1
            puts "  Affiliation ID=#{affiliation_id}: synced"
          end
        else
          stats[:not_found_in_db] += 1
          affiliation_hash['team_affiliation_id'] = nil
          stats[:cleared] += 1
          modified = true
          puts "  Affiliation ID=#{affiliation_id}: NOT FOUND - ID cleared"
        end
      end
    end

    modified
  end

  # Phase 3: Swimmers, Badges
  def process_phase3(data, stats)
    modified = false
    phase_data = data['data']

    # Swimmers
    if phase_data['swimmers'].is_a?(Array)
      phase_data['swimmers'].each do |swimmer_hash|
        next unless swimmer_hash['swimmer_id']

        swimmer_id = swimmer_hash['swimmer_id']
        stats[:total_entities] += 1

        swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
        if swimmer
          stats[:found_in_db] += 1
          if sync_swimmer!(swimmer_hash, swimmer)
            modified = true
            stats[:updated] += 1
            puts "  Swimmer ID=#{swimmer_id}: synced (#{swimmer.complete_name})"
          end
        else
          stats[:not_found_in_db] += 1
          swimmer_hash['swimmer_id'] = nil
          stats[:cleared] += 1
          modified = true

          # Clear fuzzy_matches entirely - production DB IDs are meaningless in test context
          swimmer_hash['fuzzy_matches'] = [] if swimmer_hash['fuzzy_matches'].is_a?(Array) && swimmer_hash['fuzzy_matches'].any?

          puts "  Swimmer ID=#{swimmer_id}: NOT FOUND - ID cleared"
        end
      end
    end

    # Badges
    if phase_data['badges'].is_a?(Array)
      phase_data['badges'].each do |badge_hash|
        next unless badge_hash['badge_id']

        badge_id = badge_hash['badge_id']
        stats[:total_entities] += 1

        badge = GogglesDb::Badge.find_by(id: badge_id)
        if badge
          stats[:found_in_db] += 1
          if sync_badge!(badge_hash, badge)
            modified = true
            stats[:updated] += 1
            puts "  Badge ID=#{badge_id}: synced"
          end
        else
          stats[:not_found_in_db] += 1
          badge_hash['badge_id'] = nil
          stats[:cleared] += 1
          modified = true
          puts "  Badge ID=#{badge_id}: NOT FOUND - ID cleared"
        end
      end
    end

    modified
  end

  # Phase 4: MeetingEvents
  def process_phase4(data, stats)
    modified = false
    phase_data = data['data']

    return modified unless phase_data['sessions'].is_a?(Array)

    phase_data['sessions'].each do |session_hash|
      next unless session_hash['events'].is_a?(Array)

      session_hash['events'].each do |event_hash|
        next unless event_hash['meeting_event_id']

        event_id = event_hash['meeting_event_id']
        stats[:total_entities] += 1

        event = GogglesDb::MeetingEvent.find_by(id: event_id)
        if event
          stats[:found_in_db] += 1
          if sync_meeting_event!(event_hash, event)
            modified = true
            stats[:updated] += 1
            puts "  Event ID=#{event_id}: synced"
          end
        else
          stats[:not_found_in_db] += 1
          event_hash['meeting_event_id'] = nil
          stats[:cleared] += 1
          modified = true
          puts "  Event ID=#{event_id}: NOT FOUND - ID cleared"
        end
      end
    end

    modified
  end

  # Phase 5: MeetingIndividualResults, Laps (via DataImport models)
  def process_phase5(_data, _stats)
    # Phase 5 uses DataImport models which don't have direct DB IDs yet
    # This phase is typically generated fresh, so no sync needed
    puts '  Phase 5 processing: skipped (uses DataImport models)'
    false
  end

  # Sync methods - update hash with DB values

  def sync_meeting!(hash, meeting)
    changed = false

    # Sync core attributes with DB (anonymized values)
    db_attrs = {
      'description' => meeting.description,
      'code' => meeting.code,
      'edition' => meeting.edition,
      'header_date' => meeting.header_date&.iso8601,
      'season_id' => meeting.season_id,
      'confirmed' => meeting.confirmed,
      'cancelled' => meeting.cancelled
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    changed
  end

  def sync_meeting_session!(hash, session)
    changed = false

    db_attrs = {
      'session_order' => session.session_order,
      'scheduled_date' => session.scheduled_date&.iso8601,
      'meeting_id' => session.meeting_id
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    changed
  end

  def sync_team!(hash, team)
    changed = false

    # Use anonymized DB values (FFaker-generated)
    db_attrs = {
      'name' => team.name,
      'editable_name' => team.editable_name,
      'city_id' => team.city_id
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    # Clean up fuzzy_matches: entity is matched, we don't need the matches anymore
    if hash['fuzzy_matches'].is_a?(Array) && hash['fuzzy_matches'].any?
      hash['fuzzy_matches'] = []
      changed = true
    end

    changed
  end

  def sync_team_affiliation!(hash, affiliation)
    changed = false

    db_attrs = {
      'team_id' => affiliation.team_id,
      'season_id' => affiliation.season_id,
      'name' => affiliation.name
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    changed
  end

  def sync_swimmer!(hash, swimmer)
    changed = false

    # Use anonymized DB values (FFaker-generated names)
    db_attrs = {
      'first_name' => swimmer.first_name,
      'last_name' => swimmer.last_name,
      'complete_name' => swimmer.complete_name,
      'year_of_birth' => swimmer.year_of_birth,
      'gender_type_id' => swimmer.gender_type_id
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    # Clean up fuzzy_matches: entity is matched, we don't need the matches anymore
    if hash['fuzzy_matches'].is_a?(Array) && hash['fuzzy_matches'].any?
      hash['fuzzy_matches'] = []
      changed = true
    end

    changed
  end

  def sync_badge!(hash, badge)
    changed = false

    db_attrs = {
      'swimmer_id' => badge.swimmer_id,
      'team_id' => badge.team_id,
      'season_id' => badge.season_id,
      'category_type_id' => badge.category_type_id
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    changed
  end

  def sync_meeting_event!(hash, event)
    changed = false

    db_attrs = {
      'meeting_session_id' => event.meeting_session_id,
      'event_type_id' => event.event_type_id,
      'heat_type_id' => event.heat_type_id,
      'event_order' => event.event_order
    }

    db_attrs.each do |key, value|
      if hash[key] != value
        hash[key] = value
        changed = true
      end
    end

    changed
  end
end
# rubocop:enable Rake/MethodDefinitionInTask, Metrics/CyclomaticComplexity, Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockLength
