# frozen_string_literal: true

module Health
  #
  # = Health::CancellationsController
  #
  # "Flag cancelled" (Health::MeetingCanceller), the only write of the data health report, always in two clicks:
  # - new: the dry-run preview (facts, current counts, the SQL and its digest), from a finding (finding_id: its
  #   payload 'cancel' target) or from explicit season_id + meeting_id / calendar_id;
  # - create: applies it locally and writes the numbered SQL script for the Outbox (refused when the meeting has
  #   results or when the SQL changed since the preview), then queues a 'meetings' re-run of the season, appends a
  #   'health.meeting_cancelled' / 'health.calendar_cancelled' Ops::Event and redirects to the finding (or season)
  #   page with <tt>cancelled=<script name></tt>, which shows the link to the Outbox (health/_cancelled_notice).
  #
  class CancellationsController < BaseController
    before_action :load_target

    # GET /health/cancellations/new
    def new
      @preview = @canceller.preview
    end

    # POST /health/cancellations
    def create
      result = @canceller.call(expected_digest: params[:digest])
      if result.success?
        after_cancel(result)
        cancelled = File.basename(result.sql_path.to_s)
        redirect_to(@finding ? health_finding_path(@finding, cancelled:) : health_season_path(@canceller.season.id, cancelled:))
      else
        flash[:error] = t('health.cancellations.failed', error: result.error)
        redirect_to(new_health_cancellation_path(target_params))
      end
    end

    private

    # (before_action) The canceller of the finding's payload 'cancel' target, else of the explicit ids.
    def load_target
      @finding = find_finding
      target = @finding ? finding_target(@finding) : params.permit(:season_id, :meeting_id, :calendar_id).to_h.symbolize_keys
      @canceller = Health::MeetingCanceller.new(season: target[:season_id], meeting_id: target[:meeting_id], calendar_id: target[:calendar_id])
    end

    def find_finding
      return if params[:finding_id].blank? || !ops_available?

      Ops.safely { Ops::HealthFinding.find_by(id: params[:finding_id]) }
    end

    def finding_target(finding)
      cancel = finding.payload.is_a?(Hash) ? finding.payload['cancel'].to_h : {}
      { season_id: finding.season_id, meeting_id: cancel['meeting_id'], calendar_id: cancel['calendar_id'] }
    end

    def target_params
      return { finding_id: @finding.id } if @finding

      { season_id: @canceller.season&.id, meeting_id: @canceller.meeting_id, calendar_id: @canceller.calendar_id }.compact
    end

    def after_cancel(result)
      sql_name = File.basename(result.sql_path.to_s)
      Ops.record_event!(
        kind: "health.#{@canceller.meeting_id ? 'meeting' : 'calendar'}_cancelled", level: 'success', actor: 'operator',
        season_id: @canceller.season.id, subject_type: @canceller.meeting_id ? 'meeting' : 'calendar',
        subject_key: @canceller.meeting_id || @canceller.calendar_id,
        data: { 'meeting_id' => @canceller.meeting_id, 'calendar_id' => @canceller.calendar_id, 'sql_filename' => sql_name,
                'finding_id' => @finding&.id }.compact,
        link_path: push_path_for(result.sql_path)
      )
      queue_meetings_rerun
      flash[:info] = t('health.cancellations.done', file: sql_name)
    end

    def queue_meetings_rerun
      Health::SeasonRunJob.enqueue(season_id: @canceller.season.id, group: 'meetings', trigger: 'manual')
    rescue StandardError => e
      logger.error("[Health::CancellationsController] meetings re-run not queued: #{e.class}: #{e.message}")
    end

    # The Outbox focused on the new script.
    def push_path_for(sql_path)
      Health::FindingLinks.push_path(sql_path)
    end
  end
end
