# frozen_string_literal: true

#
# = PdfScanJob
#
# Scans one results PDF in the background (phase 15, PdfResults::ScanRunner: TXT extraction, format detection, LT2
# JSON in 'results.new/<season>' on a recognised format) and stores the outcome in the ops DB
# (PdfResults::ScanState, Ops::Snapshot 'pdf_scan:<sha1>'), pinging the open PDF page (AppNotificationsChannel,
# DOM id NOTIFY_DOM_ID) and recording an ops event.
#
# Runs on the 'pipeline' worker (CPU-bound, no LLM: the 'background' worker stays free for the crawls) with priority
# 10, so a queued commit (priority 0) runs first. Enqueued only by Sources::PdfsController (an operator click); never
# by a commit or push path. Never raises (no retries): a failure is stored on the scan state.
#
class PdfScanJob < ApplicationJob
  queue_as :pipeline
  queue_with_priority 10

  # Ping of the PDF pages (Sources::PdfsController#show reloads its scan frame on it).
  NOTIFY_DOM_ID = 'sources-pdf-scan-ping'

  # Base 'crawler/data' folder (nil: Sources.data_root).
  class_attribute :data_dir, default: nil

  # - pdf_path: the PDF (a real path in 'pdfs/<season>'); ffamily: format family filter;
  # - start_page / end_page: page range (see PdfResults::ScanRunner.limit_pages); debug: verbose parser log.
  def perform(pdf_path:, ffamily: nil, start_page: nil, end_page: nil, debug: false)
    options = { ffamily:, start_page:, end_page:, debug: }.compact
    PdfResults::ScanState.start!(pdf_path, options)
    runner = PdfResults::ScanRunner.new(pdf_path:, data_root: root, **options)
    @result = runner.call
    PdfResults::ScanState.finish!(pdf_path, @result)
    record_event(pdf_path, @result.full_parse? ? 'success' : 'warning', format: @result.result_format_type)
  rescue StandardError => e
    Rails.logger.error("[PdfScanJob] #{File.basename(pdf_path.to_s)}: #{e.class}: #{e.message}")
    PdfResults::ScanState.fail!(pdf_path, "#{e.class}: #{e.message}", log_path: runner&.log_path&.to_s)
    record_event(pdf_path, 'error', error: e.message.truncate(200))
  ensure
    ping
  end

  private

  def root
    Pathname.new(data_dir || Sources.data_root).realpath
  end

  # 'sources.pdf_scan_finished' (level success: full parse, warning: stopped) / 'sources.pdf_scan_failed'.
  def record_event(pdf_path, level, **data)
    Ops.safely do
      Ops.record_event!(
        kind: level == 'error' ? 'sources.pdf_scan_failed' : 'sources.pdf_scan_finished', level:, actor: 'job',
        season_id: File.basename(File.dirname(pdf_path.to_s)).to_i.nonzero?, subject_type: 'pdf', subject_key: File.basename(pdf_path.to_s),
        data: data.stringify_keys, link_path: link_path(pdf_path)
      )
    end
  end

  def link_path(pdf_path)
    relative = Pathname.new(pdf_path.to_s).relative_path_from(root).to_s
    Rails.application.routes.url_helpers.sources_pdf_path(path: relative)
  rescue ArgumentError, SystemCallError
    nil
  end

  def ping
    ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: NOTIFY_DOM_ID, html: '' })
  rescue StandardError => e
    Rails.logger.warn("[PdfScanJob] ping failed: #{e.class}: #{e.message}")
  end
end
