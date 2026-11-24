# frozen_string_literal: true

#
# = ManifestExtractJob
#
# Extracts one pending manifest PDF into an LT4 meeting-only source through PdfManifests::Extraction (the one
# extraction path, phase 15: engine preflight, Extractor, archival to manifests.done when the result allows it), and
# tracks the attempt in SeasonBoard::ActivityLog (kind :extract), pinging the Season board. The PDF is either:
# - the pending manifest of a FIN event id (+fin_event_id+: the Season board, the pipeline planner), tracked under
#   the FIN id; or
# - a given file (+pdf_path+: the Sources Manifests tab, one file or the "next 20" batch), which must resolve inside
#   'manifests/<season>' of the data root, tracked under its source key ('src:<sha1>', label: the file name).
#
# Enqueued through SeasonBoard::Scheduler.extract! and Sources::ManifestQueue on the 'background' queue (a batch at
# priority 10, so the board crawls go first). Never enqueued by a commit or push path.
#
# Never raises: any error closes the activity as failed (no retries).
#
# Phase 10: an automatic attempt (SeasonBoard::Scheduler.extract!(origin: :auto), queued by the pipeline planner)
# carries the +run_id+ of its Ops::PipelineRun (kind 'extract', subject_key: the PDF basename): the run row follows
# the attempt (running -> done | failed; 'refused' while the 'automation.auto_extract' switch is off), and the planner
# counts the failed ones (at most 3 attempts per PDF). Every run ends by enqueuing a PipelinePlannerJob pass.
#
class ManifestExtractJob < ApplicationJob
  queue_as :background

  # Shared with MeetingCrawlJob (see there).
  limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour

  # Base 'crawler/data' folder (nil: SeasonBoard::DiskIndex.default_data_dir).
  class_attribute :data_dir, default: nil

  PREFLIGHT_MESSAGES = PdfManifests::Extraction::PREFLIGHT_MESSAGES

  # - fin_event_id: the FIN event whose pending manifest is extracted, or nil with +pdf_path+;
  # - pdf_path: the manifest PDF (absolute; nil with +fin_event_id+);
  # - engine: LLM engine name (nil for PdfManifests::ClientFactory.default_engine)
  # - run_id: the Ops::PipelineRun of an automatic attempt (nil for a manual one)
  def perform(season_id:, fin_event_id: nil, pdf_path: nil, engine: nil, run_id: nil)
    @season_id = season_id
    @fin_event_id = fin_event_id.to_s
    @pdf_path = pdf_path.to_s.presence
    @key = activity_key
    @finished = false
    @run_id = run_id
    activity_log.start!(@key, kind: :extract, label: activity_label)
    finish!(*extract(season_id, engine))
  rescue StandardError => e
    Rails.logger.error("[ManifestExtractJob] #{@key}: #{e.class}: #{e.message}")
    finish!(:failed, "error: #{e.class}: #{e.message}".truncate(200))
  ensure
    finish!(:failed, 'interrupted') unless @finished
    SeasonBoard::Snapshot.invalidate!(@season_id)
    SeasonBoard::Notifier.ping
    PipelinePlannerJob.enqueue_after(self.class.name)
  end

  private

  # ActivityLog key: the FIN event id, else the source key of the given PDF (as Sources::ManifestQueue writes it).
  def activity_key
    @fin_event_id.presence || (@pdf_path && SeasonBoard::ActivityLog.source_key('extract', @pdf_path))
  end

  # The PDF name for a Sources extraction (a board one shows the meeting name).
  def activity_label
    File.basename(@pdf_path) if @fin_event_id.blank? && @pdf_path
  end

  # The Ops::PipelineRun of an automatic attempt (+run_id+ given), moved to 'running'; nil for a manual one.
  # Fail closed: an automatic attempt is refused (@refusal set; its run closed as 'refused' when readable) while
  # 'automation.auto_extract' is off or unreadable, and when its run row cannot be read or moved to 'running' (the
  # planner's attempt cap counts those rows).
  def start_run
    return nil if @run_id.blank?

    run = Ops.safely { Ops::PipelineRun.find_by(id: @run_id) }
    return refuse_run(run, 'automation_paused') unless DataFix::Automation.enabled?(:auto_extract)

    started = run && Ops.safely(false) { run.update!(status: 'running', started_at: Time.current, job_id:) }
    started ? run : refuse_run(nil, 'ops_unavailable')
  end

  # (the run error starts with the reason code: a 'automation_paused:' refusal is not counted as an attempt by
  # SeasonBoard::PipelinePlanner.unsuccessful_extractions)
  def refuse_run(run, reason)
    @refusal = I18n.t("pipeline_automation.reasons.#{reason}")
    Ops.safely { run&.finish!(status: 'refused', error: "#{reason}: #{@refusal}") }
    nil
  end

  # Returns [status, message].
  def extract(season_id, engine)
    @run = start_run
    return [:failed, @refusal] if @refusal

    season = GogglesDb::Season.find_by(id: season_id)
    return [:failed, "unknown season #{season_id}"] unless season

    root = Pathname.new(data_dir || SeasonBoard::DiskIndex.default_data_dir)
    pdf_path = @pdf_path ? given_pdf_path(root, season.id) : fin_pdf_path(root, season.id)
    return [:failed, @pdf_path ? 'no such manifest PDF in manifests/<season>' : 'no pending manifest PDF for this FIN id'] unless pdf_path

    outcome = PdfManifests::Extraction.call(pdf_path:, engine:, data_root: root)
    [outcome.status, outcome.message]
  end

  # The pending manifest of the FIN event id (DiskIndex), or nil.
  def fin_pdf_path(root, season_id)
    SeasonBoard::DiskIndex.new(season_id:, data_dir: root).for(@fin_event_id)&.manifest_pdf_path
  end

  # The given PDF when it is a file of 'manifests/<season>' of the data root (symlinks resolved), or nil.
  def given_pdf_path(root, season_id)
    real = Sources::FileGuard.new(root:).resolve!(@pdf_path)
    real.to_s if real.extname.casecmp?('.pdf') && real.dirname == Pathname.new(root).realpath.join('manifests', season_id.to_s)
  rescue Sources::FileGuard::Refused
    nil
  end

  def finish!(status, message)
    return if @finished || @key.blank?

    @finished = true
    record_finish_event(status, message)
    Ops.safely { @run&.finish!(status: status.to_s == 'done' ? 'done' : 'failed', error: (message unless status.to_s == 'done')) }
    Ops.safely { @run&.update_columns(message: message.to_s.truncate(250)) } # rubocop:disable Rails/SkipsModelValidations
    activity_log.finish!(@key, kind: :extract, status:, message:)
  rescue StandardError => e
    Rails.logger.error("[ManifestExtractJob] cannot update the activity log: #{e.class}: #{e.message}")
  end

  # Appends 'board.extract_finished' / 'board.extract_failed' (a FIN event) or 'sources.extract_finished' /
  # 'sources.extract_failed' (a given PDF) to the ops event log (never raises).
  def record_finish_event(status, message)
    Ops.safely do
      done = status.to_s == 'done'
      Ops.record_event!(
        kind: "#{event_prefix}.#{done ? 'extract_finished' : 'extract_failed'}", level: done ? 'success' : 'error', actor: 'job',
        season_id: Integer(@season_id, exception: false), **event_subject,
        data: { 'status' => status.to_s, 'message' => message }, link_path: event_link_path
      )
    end
  end

  def fin_event? = @fin_event_id.present?

  def event_prefix = fin_event? ? 'board' : 'sources'

  def event_subject
    fin_event? ? { subject_type: 'fin_event', subject_key: @fin_event_id } : { subject_type: 'manifest_pdf', subject_key: File.basename(@pdf_path.to_s) }
  end

  def event_link_path
    helpers = Rails.application.routes.url_helpers
    fin_event? ? helpers.season_board_path : helpers.sources_manifests_path(season_id: @season_id)
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end
end
