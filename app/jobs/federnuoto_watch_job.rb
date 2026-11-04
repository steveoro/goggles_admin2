# frozen_string_literal: true

#
# = FedernuotoWatchJob
#
# Checks the FIN "Riepilogo Eventi" page for changes (see FedernuotoWatch::Checker).
#
# Scheduled hourly as a Solid Queue recurring task (config/recurring.yml) and enqueued on demand
# from the UI ("Check now", with manual: true).
#
class FedernuotoWatchJob < ApplicationJob
  queue_as :default

  # Never run two checks at the same time (e.g. the recurring one + a manual one):
  limits_concurrency key: 'federnuoto_watch', to: 1, duration: 10.minutes

  # == Params:
  # - manual: true when requested from the UI (broadcasts feedback also when nothing changed or on errors).
  def perform(manual: false)
    FedernuotoWatch::Checker.call(manual:)
  end
end
