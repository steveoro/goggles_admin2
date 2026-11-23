# frozen_string_literal: true

#
# = DbSyncController
#
# /db_sync: does the local DB still mirror the production one? (phase 08, see docs/db_sync.md)
# The last stored check (Ops::DbFingerprint) for the configured API: verdict and reasons, the per-table local /
# remote counts and max ids, admin2's own remote-only writes since the last green check, and the last checks.
# Reads only the local ops DB: no API call, so it renders in an API-offline session too.
#
# - show:        the page (<tt>id=</tt> shows a past check; <tt>frame=1</tt> renders only the live frame);
# - check:       "Check now": enqueues a full DriftCheckJob (trigger 'manual'; read-only on both sides);
# - acknowledge: marks the remote writes logged so far as reviewed (same setting as /remote_writes), then checks.
#
class DbSyncController < ApplicationController
  HISTORY_LIMIT = 20
  REMOTE_WRITES_LIMIT = 20
  # Ops::Setting key holding the time of the last "Check now" (the frame polls while that check is pending).
  REQUESTED_KEY = 'drift.check_requested_at'

  helper_method :frame_locals

  # GET /db_sync[?id=<fingerprint id>&frame=1]
  def show
    @api_url = APIProxy.configured_base_url.to_s.strip.delete_suffix('/')
    @ops_available = Ops.available?
    load_rows if @ops_available
    render(partial: 'db_sync/frame', locals: frame_locals, layout: false) if params[:frame].present?
  end

  # POST /db_sync/check
  def check
    return redirect_to(db_sync_path, alert: t('db_sync.flash.ops_missing')) unless Ops.available?

    DriftCheckJob.perform_later(trigger: 'manual')
    Ops.safely { Ops::Setting.store!(REQUESTED_KEY, Time.current.iso8601) }
    redirect_to(db_sync_path, notice: t('db_sync.flash.check_queued'))
  rescue StandardError => e
    redirect_to(db_sync_path, alert: t('db_sync.flash.check_failed', error: e.message.truncate(200)))
  end

  # POST /db_sync/acknowledge
  def acknowledge
    if Ops.safely(false) { Ops.available? && Ops::RemoteWrite.acknowledge!.present? }
      DriftCheckJob.perform_later(trigger: 'manual')
      Ops.safely { Ops::Setting.store!(REQUESTED_KEY, Time.current.iso8601) }
      redirect_to(db_sync_path, notice: t('db_sync.flash.acknowledged'))
    else
      redirect_to(db_sync_path, alert: t('db_sync.flash.ops_missing'))
    end
  end

  protected

  # The page reads only the local ops DB; "Check now" only enqueues the job (which uses the background JWT).
  def api_offline_allowed?
    true
  end

  private

  def load_rows # rubocop:disable Metrics/AbcSize
    scope = Ops::DbFingerprint.for_base_url(@api_url)
    @latest = scope.recent.first
    @fingerprint = params[:id].present? ? scope.find_by(id: params[:id]) : @latest
    @fingerprint ||= @latest
    @history = scope.recent.limit(HISTORY_LIMIT).to_a
    @last_green_at = Ops::DbFingerprint.last_green_at(@api_url)
    @acknowledged_at = Ops::RemoteWrite.acknowledged_at
    since = [@last_green_at, @acknowledged_at].compact.max
    @remote_writes = Ops::RemoteWrite.for_base_url(@api_url).succeeded.since(since).recent.limit(REMOTE_WRITES_LIMIT).to_a
    @capabilities = APICapabilities.new(base_url: @api_url)
    @check_pending = check_pending?
  end

  # True while a "Check now" is newer than the last stored check (the frame keeps polling).
  def check_pending?
    requested = Ops::Setting.fetch(REQUESTED_KEY)
    return false if requested.blank?

    time = Time.zone.parse(requested.to_s)
    time.present? && time > 10.minutes.ago && (@latest.nil? || @latest.taken_at < time)
  rescue ArgumentError
    false
  end

  def frame_locals
    {
      ops_available: @ops_available, api_url: @api_url, fingerprint: @fingerprint, latest: @latest, history: @history || [],
      remote_writes: @remote_writes || [], last_green_at: @last_green_at, acknowledged_at: @acknowledged_at,
      capabilities: @capabilities, check_pending: @check_pending
    }
  end
end
