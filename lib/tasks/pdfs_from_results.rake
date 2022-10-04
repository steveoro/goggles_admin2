# frozen_string_literal: true

require 'goggles_db'

namespace :pdf_files do
  desc <<~DESC
    Extracts all 'resultsPdfURL's & 'manifestURL's found in all the result files stored in the specified season
    "results.new" folder (assuming there are any *.json files stored there) and saves each URL found to
    a destination text file for later processing.

    Two different text result files are created: 1 for each Manifest URL & 1 for each results file URL found.

    Each text file generated has one single line for each meeting with format:

          "<DOWNLOAD_URL>";"<BASE_FILE_NAME>"<EOLN>

    The file downloaded using "<DOWNLOAD_URL>" subsequently can then be saved using the accompaining
    "<BASE_FILE_NAME>" suggested.


    Options: [season=season#id|<212>]

      - season: season ID used as sub-folder for storing the individual JSON result files.

  DESC
  task from_results: :environment do
    puts "\r\n*** Extract Fixture files from JSON result files ***"

    season_id = ENV.include?('season') ? ENV['season'].to_i : 212
    puts('==> WARNING: unsupported season ID! Season 172 and prior are still WIP due to different layout.') unless [182, 192, 202, 212].include?(season_id)
    base_path = Rails.root.join("crawler/data/results.new/#{season_id}")
    files = Dir.glob("#{base_path}/*.json").sort
    puts "--> Found #{files.count} files. Processing..."
    puts "\r\n"
    manifest_urls = []
    results_urls = []

    files.each do |filename|
      hash = JSON.parse(File.read(filename))
      dest_basename = File.basename(filename, '.json')
      putc '.'
      manifest_urls << "\"#{hash['manifestURL']}\";\"#{dest_basename}-man.pdf\"" if hash['manifestURL'].present?
      results_urls << "\"#{hash['resultsPdfURL']}\";\"#{dest_basename}-res.pdf\"" if hash['resultsPdfURL'].present?
    end.compact
    puts "\r\n"

    save_array_of_lines_on_file(manifest_urls, base_path, 'manifest')
    save_array_of_lines_on_file(results_urls, base_path, 'results')
    puts "\r\n"
  end

  private

  # Saves the specified 'array_of_lines' into a single text file under 'base_path'.
  # 'type_name' is used to discriminate between the type of content to which the URLs in the destination file
  # refer to. (Namely: 'manifest' & 'results'.)
  def save_array_of_lines_on_file(array_of_lines, base_path, type_name)
    if array_of_lines.count.positive?
      puts "\r\n--> Extracted #{array_of_lines.count} #{type_name} PDF URLs."
      dest_file = "#{base_path}/#{type_name}_urls.txt"
      File.open(dest_file, 'w+') do |f|
        f.write(array_of_lines.join("\r\n"))
      end
      puts "--> '#{dest_file}' created."
    else
      puts "No #{type_name} URLs extracted."
    end
  end
end
