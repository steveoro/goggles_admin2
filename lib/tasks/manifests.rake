# frozen_string_literal: true

#
# = Manifest extraction tasks
#
#   Extracts meeting data (name, dates, venue/pool, event program) from the
#   PDF manifests stored under 'crawler/data/manifests/<season_id>/' and
#   generates "layoutType: 4" JSON source files under 'crawler/data/results.new/<season_id>/'
#   so that the phased data-import wizard opens already prefilled.
#
#   Processed manifests (both the source .pdf and its extracted '.txt' sibling)
#   are then moved to 'crawler/data/manifests.done/<season_id>/', much like the
#   result datafiles under 'results.new' => 'results.done'.
#
#   Phase 15: one extraction path, PdfManifests::Extraction (the same as the
#   ManifestExtractJob of the Season board and of the Sources Manifests tab),
#   run inline one file at a time; each file gets the same activity entry as a
#   Sources extraction (SeasonBoard::ActivityLog), so the UI sees the run.
#
#   The extraction uses a pluggable LLM engine ('devin' by default: the Devin
#   CLI in `devin -p` non-interactive mode; 'ollama': a locally-running Ollama
#   server). Scanned/image-only PDFs are processed through the engine's vision
#   capabilities only when actually available; those files are skipped
#   otherwise.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :manifests do # rubocop:disable Metrics/BlockLength
  desc <<~DESC
    Extracts meeting data from PDF manifests into LT4 source files.
    Processed manifests (.pdf + extracted .txt) are moved to 'manifests.done/<season#id>/'.

    Options: [season=<season#id>|<latest FIN Masters season>]
             [file=<path/to/manifest.pdf>]  (single file, overrides 'season')
             [force=1]                      (regenerate existing -lt4.json outputs)
             [engine=devin|ollama]          (default: MANIFEST_ENGINE or 'devin')
             [model=<model_id>]             (default: DEVIN_MANIFEST_MODEL 'swe-2-high' /
                                             OLLAMA_MANIFEST_MODEL 'gemma4:e4b')
  DESC
  task extract: :environment do # rubocop:disable Metrics/BlockLength
    season_id = ENV.fetch('season') { SeasonDefaults.default_season_id }.to_i
    force = ENV['force'].present?
    model = ENV['model'].presence

    puts("\r\n*** Task: manifests:extract - season: #{season_id} ***")

    client = PdfManifests::ClientFactory.build(engine: ENV.fetch('engine', nil), model: model)
    unless client.available?
      puts "ABORTED: #{client.engine_name} engine not available - #{client.unavailable_hint}"
      next
    end
    unless client.model_available?
      model_ids = client.models.keys.sort
      listed = model_ids.first(20).join(', ')
      listed += ", ... (#{model_ids.size} total)" if model_ids.size > 20
      puts "ABORTED: model '#{client.model}' not available for #{client.engine_name} - #{client.model_missing_hint}\r\n     " \
           "Available models: #{listed}"
      next
    end
    puts "--> #{client.engine_name} OK - text model: #{client.model}" \
         "#{client.vision_available? ? " | vision model: #{client.vision_model}" : ' | (no vision model - scanned PDFs will be skipped)'}"

    data_root = Sources.data_root
    pdf_list =
      if ENV['file'].present?
        [ENV['file'].to_s]
      else
        data_root.glob("manifests/#{season_id}/*.pdf").map(&:to_s).sort
      end
    if pdf_list.empty?
      puts 'No manifest PDFs found.'
      next
    end
    puts "--> Found #{pdf_list.size} manifest file(s)\r\n\r\n"

    stats = { extracted: 0, skipped: 0, failed: 0 }
    activity_log = SeasonBoard::ActivityLog.new
    pdf_list.each do |pdf_path|
      base = File.basename(pdf_path)
      print "--> #{base} ... "
      # (the same activity entry as a Sources extraction, so that the UI sees the inline run)
      key = SeasonBoard::ActivityLog.source_key('extract', File.exist?(pdf_path) ? File.realpath(pdf_path) : pdf_path)
      activity_log.start!(key, kind: :extract, origin: :manual, label: base)
      # (the engine was checked above, once for the whole run)
      outcome = PdfManifests::Extraction.call(pdf_path:, force:, data_root:, client:, preflight: false)
      activity_log.finish!(key, kind: :extract, status: outcome.status, message: outcome.message)
      result = outcome.extractor_result

      if result.success?
        stats[:extracted] += 1
        puts "OK (#{result.events_count} events) -> #{File.basename(result.out_path)}"
      elsif result.archivable_skip?
        stats[:skipped] += 1
        puts "skipped (#{result.skipped_reason})"
      else
        stats[:failed] += 1
        puts "FAILED: #{result.skipped_reason}"
      end
      Array(result.warnings).each { |w| puts "    warn: #{w}" }
    end

    puts "\r\n== Done: #{stats[:extracted]} extracted, #{stats[:skipped]} skipped, #{stats[:failed]} failed =="
  end
end
