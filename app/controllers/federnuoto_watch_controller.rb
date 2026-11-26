# frozen_string_literal: true

#
# = FedernuotoWatchController
#
# Actions for the FIN "Riepilogo Eventi" watcher alert (see FedernuotoWatch & FedernuotoWatchJob).
#
class FedernuotoWatchController < ApplicationController
  # [POST] Enqueues an immediate check; the outcome is pushed live through AppNotificationsChannel.
  def check
    FedernuotoWatchJob.perform_later(manual: true)
    flash[:info] = I18n.t('federnuoto_watch.check.started')
    redirect_back_or_to(root_path)
  end

  # [POST] Acknowledges (dismisses) the pending change alert (FedernuotoWatch::Acknowledge, actor operator): removes it
  # from every open tab and logs it. With +digest+ (the snapshot the alert showed), nothing is acknowledged when a newer
  # change landed meanwhile: that one shows again on the next page load.
  def acknowledge
    FedernuotoWatch::Acknowledge.call(actor: :operator, reason: 'operator', expected_digest: params[:digest].presence)
    head(:no_content)
  end

  # [POST] Dismisses one FIN calendar notice of the "Needs you" list (Inbox::Sources::FINNotice), +id+: its event id.
  def dismiss_notice
    if Inbox::Sources::FINNotice.dismiss!(params[:id])
      flash[:info] = I18n.t('federnuoto_watch.notice.dismissed')
    else
      flash[:warning] = I18n.t('federnuoto_watch.notice.not_dismissed')
    end
    redirect_back_or_to(root_path)
  end
end
