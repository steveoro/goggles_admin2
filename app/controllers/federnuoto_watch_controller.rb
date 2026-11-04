# frozen_string_literal: true

#
# = FedernuotoWatchController
#
# Actions for the FIN "Riepilogo Eventi" watcher alert (see FedernuotoWatch & FedernuotoWatchJob).
#
class FedernuotoWatchController < ApplicationController
  # Sub-menu item of the FIN calendar crawler matching the watched page:
  CALENDAR_SUB_MENU = 'Riepilogo Eventi'

  # [POST] Enqueues an immediate check; the outcome is pushed live through AppNotificationsChannel.
  def check
    FedernuotoWatchJob.perform_later(manual: true)
    flash[:info] = I18n.t('federnuoto_watch.check.started')
    redirect_back_or_to(root_path)
  end

  # [POST] Acknowledges (dismisses) the pending change alert.
  def acknowledge
    FedernuotoWatch::StateStore.new.acknowledge!
    head(:no_content)
  end

  # [POST] Starts the crawler server if needed, then opens the Pull dashboard with the
  # calendar sub-menu preset to the watched page.
  def pull_calendar
    launch_result = CrawlerLauncher.new.ensure_running!
    # (No need to tell when it's already running: the Pull page shows the status anyway)
    flash_symbol, message = CrawlerLauncher.flash_for(launch_result)
    flash[flash_symbol] = message unless launch_result == :already_running
    redirect_to(pull_index_path(sub_menu_type: CALENDAR_SUB_MENU))
  end
end
