# frozen_string_literal: true

require 'goggles_db'

namespace :fixtures do
  desc <<~DESC
    Extracts specific text strings as fixtures from the JSON results stored
    in the folder of a specific season.

    Each '.json' file found in the specified season folder will be scanned for specific
    columns of text and the found text will be stored as a fixture is a separate, dedicated file.

    The output files will be stored in the 'spec/fixtures/parser' folder, one file per
    extracted array ("venues.yml", "addresses.yml", ...).

    Options: [season=season#id|<212>]
             [limit=max_num_of_files|<-1>]

      - season: season ID used as sub-folder for storing the individual JSON result files.

      - limit: maximum number of files (+1) to be scanned; default: -1 (no limits)

  DESC
  task extract_from_results: :environment do
    puts "\r\n*** Extract Fixture files from JSON result files ***"

    season_id = ENV.include?('season') ? ENV['season'].to_i : 212
    puts("==> WARNING: unsupported season ID! Season 172 and prior are still WIP due to different layout.") unless [182, 192, 202, 212].include?(season_id)

    limit = ENV.include?('limit') ? ENV['limit'].to_i : -1
    files = Dir.glob(Rails.root.join("crawler/data/results.new/#{season_id}/*.json")).sort
    puts "--> Found #{files.count} files#{ limit >= 0 ? ". Limit: #{limit}" : ''}. Processing..."
    puts "\r\n"

    descriptions = []
    venues = []
    addresses = []
    organizations = []
    registrations = []

    event_titles = []
    swimmer_names = []
    team_names = []

    # ANSI color codes: 31m = red; 32m = green; 33m = yellow; 34m = blue; 37m = white
    files[0..limit].each do |file|
      $stdout.write("\033[1;33;34mr\033[0m")
      json = File.read(file)
      $stdout.write("\033[1;33;37mp\033[0m")
      data = JSON.parse(json)

      descriptions << data['name'] if data['name'].present? && !descriptions.include?(data['name'])
      $stdout.write("\033[1;33;32m.\033[0m")

      venues << data['venue1'] if data['venue1'].present? && !venues.include?(data['venue1'])
      venues << data['venue2'] if data['venue2'].present? && !venues.include?(data['venue2'])
      $stdout.write("\033[1;33;32m.\033[0m")

      addresses << data['address1'] if data['address1'].present? && !addresses.include?(data['address1'])
      addresses << data['address2'] if data['address2'].present? && !addresses.include?(data['address2'])
      $stdout.write("\033[1;33;32m.\033[0m")

      organizations << data['organization'] if data['organization'].present? &&
                                               !organizations.include?(data['organization'])
      $stdout.write("\033[1;33;32m.\033[0m")

      registrations << data['registration'] if data['registration'].present? &&
                                               !registrations.include?(data['registration'])
      $stdout.write("\033[1;33;32m.\033[0m")

      # Sub-loop:
      if data['sections'].present?
        data['sections'].each do |section|
          event_titles << section['title'] if section['title'].present?
          if section['rows'].present?
            swimmer_names << section['rows'].map { |row| row['name'] if row['name'].present? }.compact
            team_names << section['rows'].map { |row| row['team'] if row['team'].present? }.compact
          end
        end
      end
    end

    puts "\r\n\r\n--> Preparing output:"
    [
      { name: 'descriptions', data: descriptions.compact.uniq.sort },
      { name: 'venues', data: venues.compact.uniq.sort },
      { name: 'addresses', data: addresses.compact.uniq.sort },
      { name: 'organizations', data: organizations.compact.uniq.sort },
      { name: 'registrations', data: registrations.compact.uniq.sort },

      { name: 'event_titles', data: event_titles.flatten.compact.uniq.sort },
      { name: 'swimmer_names', data: swimmer_names.flatten.compact.uniq.sort },
      { name: 'team_names', data: team_names.flatten.compact.uniq.sort }
    ].each do |item|
      file_name = Rails.root.join("spec/fixtures/parser/#{item[:name]}-#{season_id}.yml")
      puts "    - Saving #{file_name}"
      File.write(file_name, item[:data].to_yaml, mode: 'w')
    end
  end
end
