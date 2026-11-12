# frozen_string_literal: true

#
# = ManifestExtractJob
#
# Extracts the pending manifest PDF of a single FIN event id (PdfManifests::Extractor) into an
# LT4 meeting-only source, archiving the PDF to manifests.done when the result allows it, and
# tracks the attempt in SeasonBoard::ActivityLog (kind :extract), pinging the Season board.
#
# Enqueued through SeasonBoard::Scheduler.extract! on the 'background' queue. The season-wide
# PdfManifests::BatchRunner (legacy Pull page) is left untouched: this job refuses to run while
# a batch is running, and applies the same preflight checks.
#
# Never raises: any error closes the activity as failed (no retries).
#
class ManifestExtractJob < ApplicationJob
  queue_as :background

  # Shared with MeetingCrawlJob (see there).
  limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour

  # Base 'crawler/data' folder (nil: SeasonBoard::DiskIndex.default_data_dir).
  class_attribute :data_dir, default: nil

  PREFLIGHT_MESSAGES = {
    engine_unavailable: 'LLM engine unavailable',
    model_missing: 'LLM model missing',
    no_manifests: 'no manifest PDF to extract'
  }.freeze

  # - engine: LLM engine name (nil for PdfManifests::ClientFactory.default_engine)
  def perform(season_id:, fin_event_id:, engine: nil)
    @fin_event_id = fin_event_id.to_s
    @finished = false
    activity_log.start!(@fin_event_id, kind: :extract)
    finish!(*extract(season_id, engine))
  rescue StandardError => e
    Rails.logger.error("[ManifestExtractJob] FIN #{@fin_event_id}: #{e.class}: #{e.message}")
    finish!(:failed, "error: #{e.class}: #{e.message}".truncate(200))
  ensure
    finish!(:failed, 'interrupted') unless @finished
    SeasonBoard::Notifier.ping
  end

  private

  # Returns [status, message].
  def extract(season_id, engine)
    season = GogglesDb::Season.find_by(id: season_id)
    return [:failed, "unknown season #{season_id}"] unless season

    root = Pathname.new(data_dir || SeasonBoard::DiskIndex.default_data_dir)
    return [:failed, 'a season-wide manifest extraction is running'] if PdfManifests::BatchRunner.running?(data_root: root)

    pdf_path = SeasonBoard::DiskIndex.new(season_id: season.id, data_dir: root).for(@fin_event_id)&.manifest_pdf_path
    return [:failed, 'no pending manifest PDF for this FIN id'] unless pdf_path

    run_extractor(PdfManifests::BatchRunner.new(season_id: season.id, engine:, data_root: root), pdf_path, root)
  end

  # Same preflight checks as the season-wide batch, then the single-file extraction & archival.
  def run_extractor(runner, pdf_path, root)
    preflight = runner.preflight_error
    return [:failed, PREFLIGHT_MESSAGES.fetch(preflight, preflight.to_s)] if preflight

    result = PdfManifests::Extractor.new(client: runner.client, results_root: root.join('results.new')).call(pdf_path)
    return [:failed, "extraction failed: #{result.skipped_reason}".truncate(200)] unless result.archivable?

    PdfManifests::BatchRunner.archive(pdf_path)
    [:done, result.success? ? "extracted (#{result.events_count.to_i} events)" : "skipped: #{result.skipped_reason}".truncate(200)]
  end

  def finish!(status, message)
    return if @finished || @fin_event_id.blank?

    @finished = true
    activity_log.finish!(@fin_event_id, kind: :extract, status:, message:)
  rescue StandardError => e
    Rails.logger.error("[ManifestExtractJob] cannot update the activity log: #{e.class}: #{e.message}")
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end
end
