# frozen_string_literal: true

require 'fileutils'

#
# = Manifest extraction tasks
#
#   Extracts meeting data (name, dates, venue/pool, event program) from the
#   PDF manifests stored under 'crawler/data/manifests/<season_id>/' and
#   generates "layoutType: 4" JSON source files under 'crawler/data/results.new/<season_id>/'
#   so that the phased data-import wizard opens already prefilled.
#
#   The extraction uses a locally-running Ollama server (default model:
#   'gemma4:e4b'). Scanned/image-only PDFs are processed through the vision
#   capabilities of the model only when both Ollama and the vision model are
#   actually installed and serving; those files are skipped otherwise.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :manifests do # rubocop:disable Metrics/BlockLength
  # Default Season#id used when no explicit 'season' option is given
  DEFAULT_SEASON_ID = 262 unless defined? DEFAULT_SEASON_ID

  desc <<~DESC
    Extracts meeting data from PDF manifests into LT4 source files.

    Options: [season=<season#id>|#{DEFAULT_SEASON_ID}]
             [file=<path/to/manifest.pdf>]  (single file, overrides 'season')
             [force=1]                      (regenerate existing -lt4.json outputs)
             [model=<ollama_model>]         (default: OLLAMA_MANIFEST_MODEL or 'gemma4:e4b')
  DESC
  task extract: :environment do # rubocop:disable Metrics/BlockLength
    season_id = ENV.fetch('season', DEFAULT_SEASON_ID).to_i
    force = ENV['force'].present?
    model = ENV['model'].presence

    puts("\r\n*** Task: manifests:extract - season: #{season_id} ***")

    client = PdfManifests::OllamaClient.new(model: model)
    unless client.available?
      puts 'ABORTED: Ollama is not installed or not running. ' \
           'Start it with `ollama serve` and retry.'
      next
    end
    puts "--> Ollama OK - text model: #{client.model}" \
         "#{client.vision_available? ? " | vision model: #{client.vision_model}" : ' | (no vision model - scanned PDFs will be skipped)'}"

    pdf_list =
      if ENV['file'].present?
        [ENV['file'].to_s]
      else
        Rails.root.glob("crawler/data/manifests/#{season_id}/*.pdf")
      end
    if pdf_list.empty?
      puts 'No manifest PDFs found.'
      next
    end
    puts "--> Found #{pdf_list.size} manifest file(s)\r\n\r\n"

    extractor = PdfManifests::Extractor.new(client: client)
    stats = { extracted: 0, skipped: 0, failed: 0 }

    pdf_list.each do |pdf_path|
      base = File.basename(pdf_path)
      print "--> #{base} ... "
      result = extractor.call(pdf_path, force: force)

      if result.success?
        stats[:extracted] += 1
        puts "OK (#{result.events_count} events) -> #{File.basename(result.out_path)}"
      elsif result.skipped_reason.to_s.start_with?('output already exists')
        stats[:skipped] += 1
        puts 'skipped (already extracted)'
      else
        stats[:failed] += 1
        puts "FAILED: #{result.skipped_reason}"
      end
      Array(result.warnings).each { |w| puts "    warn: #{w}" }
    end

    puts "\r\n== Done: #{stats[:extracted]} extracted, #{stats[:skipped]} skipped, #{stats[:failed]} failed =="
  end
end
