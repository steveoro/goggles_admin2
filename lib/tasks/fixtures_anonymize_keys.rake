# frozen_string_literal: true

require 'goggles_db'
require 'ffaker'

# rubocop:disable Metrics/BlockLength
namespace :fixtures do
  desc <<~DESC
    Anonymizes swimmer keys in phase fixture files for privacy compliance.

    ⚠️  CRITICAL: Must run AFTER fixtures:sync_with_testdb

    For each swimmer in phase 3 files:
    - If matched (swimmer_id present): Uses anonymized DB values for key
    - If unmatched (swimmer_id blank): Generates new FFaker last_name for key

    This ensures all personal names are anonymized in public fixtures.

    Options: [fixture_dir=<spec/fixtures/import>]
             [fixture_pattern=<200RA>]
             [dry_run=<true|false>]

    Examples:
      RAILS_ENV=test bundle exec rake fixtures:anonymize_keys
      RAILS_ENV=test bundle exec rake fixtures:anonymize_keys fixture_pattern=200RA dry_run=true

  DESC

  task anonymize_keys: :environment do
    # CRITICAL: Must run in test environment to access test database
    unless Rails.env.test?
      puts "\r\n⚠️  ERROR: This task MUST run in test environment!"
      puts 'Usage: RAILS_ENV=test bundle exec rake fixtures:anonymize_keys'
      exit 1
    end

    puts "\r\n*** Anonymize Swimmer Keys in Phase Fixtures ***"
    puts "Environment: #{Rails.env} ✓"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    puts '-' * 80

    fixture_dir = ENV.fetch('fixture_dir', 'spec/fixtures/import')
    fixture_pattern = ENV.fetch('fixture_pattern', '200RA')
    dry_run = ENV.fetch('dry_run', 'false').downcase == 'true'

    fixture_path = Rails.root.join(fixture_dir)
    raise "Fixture directory not found: #{fixture_path}" unless File.directory?(fixture_path)

    # Find all phase 3 files (swimmers)
    all_files = Dir.glob(File.join(fixture_path, '*-phase3.json'))
    files = all_files.reject { |f| File.symlink?(f) }.select { |f| File.basename(f).include?(fixture_pattern) }

    if files.empty?
      puts "No phase 3 fixture files found matching pattern: *#{fixture_pattern}*-phase3.json"
      puts "Searched in: #{fixture_path}"
      exit 0
    end

    puts "Found #{files.count} phase 3 file(s) to process:"
    files.each { |f| puts "  - #{File.basename(f)}" }
    puts "\r\nMode: #{dry_run ? 'DRY RUN (no changes will be written)' : 'WRITE MODE'}"
    puts '-' * 80

    stats = {
      total_swimmers: 0,
      matched_anonymized: 0,
      unmatched_anonymized: 0,
      keys_replaced: 0
    }

    files.each do |file_path|
      process_phase3_file(file_path, dry_run, stats)
    end

    puts "\r\n#{'=' * 80}"
    puts 'SUMMARY:'
    puts "  Total swimmers processed: #{stats[:total_swimmers]}"
    puts "  Matched (DB anonymized):  #{stats[:matched_anonymized]}"
    puts "  Unmatched (FFaker):       #{stats[:unmatched_anonymized]}"
    puts "  Key replacements made:    #{stats[:keys_replaced]}"
    puts '=' * 80
    puts "\r\nAnonymization complete!"
  end

  # Process a single phase 3 file
  def process_phase3_file(file_path, dry_run, stats)
    filename = File.basename(file_path)
    puts "\r\n--- Processing: #{filename} ---"

    data = JSON.parse(File.read(file_path))

    key_mappings = {}
    modified = false

    phase_data = data['data']
    return unless phase_data['swimmers'].is_a?(Array)

    # Build key mappings and update swimmer data
    phase_data['swimmers'].each do |swimmer_hash|
      stats[:total_swimmers] += 1
      old_key = swimmer_hash['key']
      next unless old_key

      new_key = if swimmer_hash['swimmer_id'].present?
                  # Matched: use DB anonymized values (already updated by sync)
                  build_key_from_db(swimmer_hash)
                else
                  # Unmatched: generate FFaker last_name and update hash
                  build_key_with_ffaker(swimmer_hash)
                end

      next unless new_key && new_key != old_key

      # Update the key in the swimmer hash
      swimmer_hash['key'] = new_key
      key_mappings[old_key] = new_key
      modified = true

      if swimmer_hash['swimmer_id'].present?
        stats[:matched_anonymized] += 1
        puts "  Matched: '#{old_key}' → '#{new_key}' (DB)"
      else
        stats[:unmatched_anonymized] += 1
        puts "  Unmatched: '#{old_key}' → '#{new_key}' (FFaker)"
      end
    end

    # Replace key references in badges (using 'swimmer_key' field)
    if phase_data['badges'].is_a?(Array) && key_mappings.any?
      phase_data['badges'].each do |badge_hash|
        old_key = badge_hash['swimmer_key']
        if old_key && key_mappings[old_key]
          badge_hash['swimmer_key'] = key_mappings[old_key]
          stats[:keys_replaced] += 1
        end
      end
      puts "    → Updated #{stats[:keys_replaced]} badge swimmer_key references" if stats[:keys_replaced].positive?
    end

    # Write back if modified
    if modified
      if dry_run
        puts "  [DRY RUN] Would update file with #{key_mappings.count} key replacements"
      else
        File.write(file_path, JSON.pretty_generate(data))
        puts "  ✓ File updated (#{key_mappings.count} keys anonymized)"
      end
    else
      puts '  No changes needed (all keys already anonymized)'
    end
  end

  # Build key from DB values (already anonymized)
  def build_key_from_db(swimmer_hash)
    last_name = swimmer_hash['last_name']
    first_name = swimmer_hash['first_name']
    year = swimmer_hash['year_of_birth']

    return nil unless last_name && first_name && year

    # Format: "LAST_NAME|FirstName|year"
    "#{last_name.upcase}|#{first_name}|#{year}"
  end

  # Build key with FFaker for unmatched swimmers
  def build_key_with_ffaker(swimmer_hash)
    # Keep first_name, generate new last_name
    first_name = swimmer_hash['first_name']
    year = swimmer_hash['year_of_birth']

    return nil unless first_name && year

    # Generate FFaker last name
    new_last_name = FFaker::Name.last_name

    # Update the hash with new anonymized values
    swimmer_hash['last_name'] = new_last_name
    swimmer_hash['complete_name'] = "#{new_last_name} #{first_name}"

    # Format: "LAST_NAME|FirstName|year"
    "#{new_last_name.upcase}|#{first_name}|#{year}"
  end
end
# rubocop:enable Metrics/BlockLength
