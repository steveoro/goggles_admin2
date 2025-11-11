#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Phase5Populator format detection
# Run with: rails runner test_format_detection.rb

require 'json'

puts "\n🔍 Testing Phase5Populator Format Detection\n"
puts '=' * 60

# Test file: LT2 relay file
lt2_file = 'crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json'

if File.exist?(lt2_file)
  puts "\n✅ Test 1: LT2 Format Detection"
  puts "File: #{lt2_file}"

  # Create minimal phase paths (may not exist, that's ok for format detection)
  base_path = lt2_file.gsub('.json', '')

  populator = Import::Phase5Populator.new(
    source_path: lt2_file,
    phase1_path: "#{base_path}-phase1.json",
    phase2_path: "#{base_path}-phase2.json",
    phase3_path: "#{base_path}-phase3.json",
    phase4_path: "#{base_path}-phase4.json"
  )

  # Access source_data to load file
  populator.send(:load_phase_files!)

  # Test format detection
  format = populator.send(:source_format)
  puts "Detected format: #{format}"

  if format == :lt2
    puts '✅ PASS: Correctly detected LT2 format'

    # Check for LT2 keys
    source = populator.source_data
    has_relay = source.key?('meeting_relay_result')
    has_individual = source.key?('meeting_individual_result')
    relay_count = source['meeting_relay_result']&.size || 0

    puts "  - Has meeting_relay_result: #{has_relay} (#{relay_count} results)"
    puts "  - Has meeting_individual_result: #{has_individual}"
    puts "  - Has events array: #{source.key?('events')}"
  else
    puts "❌ FAIL: Expected :lt2, got :#{format}"
  end
else
  puts "\n⚠️  Test 1 SKIPPED: LT2 file not found"
  puts "File: #{lt2_file}"
end

# Test 2: Find an LT4 file (if available)
puts "\n" + ('=' * 60)
puts "\n🔍 Searching for LT4 test file..."

# Look for any file with events array
lt4_candidates = Dir.glob('crawler/data/results.new/**/*.json').select do |f|
  next if f.include?('phase')

  data = begin
    JSON.parse(File.read(f))
  rescue StandardError
    nil
  end
  data&.key?('events')
end.first(3)

if lt4_candidates.any?
  lt4_file = lt4_candidates.first
  puts "\n✅ Test 2: LT4 Format Detection"
  puts "File: #{lt4_file}"

  base_path = lt4_file.gsub('.json', '')

  populator = Import::Phase5Populator.new(
    source_path: lt4_file,
    phase1_path: "#{base_path}-phase1.json",
    phase2_path: "#{base_path}-phase2.json",
    phase3_path: "#{base_path}-phase3.json",
    phase4_path: "#{base_path}-phase4.json"
  )

  populator.send(:load_phase_files!)
  format = populator.send(:source_format)
  puts "Detected format: #{format}"

  if format == :lt4
    puts '✅ PASS: Correctly detected LT4 format'

    source = populator.source_data
    events_count = source['events']&.size || 0
    puts "  - Has events array: true (#{events_count} events)"
    puts "  - Has meeting_relay_result: #{source.key?('meeting_relay_result')}"
  else
    puts "❌ FAIL: Expected :lt4, got :#{format}"
  end
else
  puts "\n⚠️  Test 2 SKIPPED: No LT4 files found"
end

puts "\n" + ('=' * 60)
puts "✅ Format detection tests complete!\n\n"
