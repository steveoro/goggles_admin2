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


    Options: [season=season#id|<232>]
             [source='results.done'|<'results.new'>]

      - season: season ID used as sub-folder for storing the individual JSON result files.
      - source: source sub-folder (default: 'results.new/<season_id>')

  DESC
  task from_results: :environment do
    puts "\r\n*** Extract Fixture files from JSON result files ***"

    season_id = ENV.include?('season') ? ENV['season'].to_i : 232
    source = ENV.include?('source') ? ENV['source'] : 'results.new'
    puts('==> WARNING: unsupported season ID! Season 172 and prior are still WIP due to different layout.') unless (182..232).step(10).to_a.include?(season_id)
    base_path = Rails.root.join("crawler/data/#{source}/#{season_id}")
    files = Dir.glob("#{base_path}/*.json")
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

  desc <<~DESC
    Given a Season ID, queries all local Meeting IDs that DO/DO-NOT HAVE MIRs or MRRs associated.

    The lack of MIRs is usually a red flag for meetings that either have been cancelled
    or have a data-import still pending.
    (MIRs should always be there for a Meeting that has occurred, whereas MRRs may not have been
     set at all, depending by the organization hosting it.)

    Options: [season=season#id|<nil=232>]
             [mrr=true|<nil=false>]
             [presence=true|<nil=false>]

      - season: season ID
      - mrr: when 'true' (or not blank) will count MRRs instead of MIRs
      - presence: search for zero siblings (default, either MIRs or MRRs) or for their positive count

  DESC
  task missing: :environment do
    includee = ENV.include?('mrr') ? :meeting_relay_results : :meeting_individual_results
    # For presence, we'll reject the zero? counts, whereas for absence, we'll reject the positive? counts:
    reject_check_name = ENV.include?('presence') ? :zero? : :positive?
    puts "\r\n*** Find Meetings #{reject_check_name == :zero? ? 'WITH' : 'WITHOUT'} #{includee} rows ***"

    season_id = ENV.include?('season') ? ENV['season'].to_i : 232
    puts "\r\n"
    puts "--> Season #{season_id}:"
    meeting_keys = GogglesDb::Meeting.where(season_id: season_id).includes(includee)
                                     .group('meetings.id', 'meetings.description', 'meetings.header_date')
                                     .count("#{includee}.id")
                                     .reject { |_k, count| count.send(reject_check_name) }
    meeting_keys.each_key { |keys| puts "ID #{keys.first}: [#{keys.third}] \"#{keys.second}\"" }
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
      File.write(dest_file, array_of_lines.join("\r\n"))
      puts "--> '#{dest_file}' created."
    else
      puts "No #{type_name} URLs extracted."
    end
  end
end
