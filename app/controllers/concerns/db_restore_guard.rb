# frozen_string_literal: true

#
# = DbRestoreGuard
#
# Request side of DbRestore::Lock (phase 14), included by ApplicationController. Its +db_restore_guard+ callback is
# prepended, so it runs before +app_settings_row+, the JWT check and Devise: while a guided restore holds the lock
# (MySQL may be dropped or half loaded) every request is answered from the ops DB only:
# - HTML: the restore layout (db_restore/locked) with status 503 and a link to the progress page;
# - anything else: 503 JSON <tt>{ error: 'db_restore_in_progress', run_id: }</tt>.
# Skipped only by the progress page actions of DbRestoreController (+skip_db_restore_guard+).
#
# Also rescues the MySQL adapter errors raised while the lock is active by callbacks that run before it (the
# Devise callbacks prepended by its own controllers), answering the same page; outside a restore they are re-raised.
#
# Outside a restore it reconnects the MySQL pool once after a restore (DbRestore::Reconnect).
#
module DbRestoreGuard
  extend ActiveSupport::Concern

  # Session key of the progress page grant of this browser: { 'run_id', 'until' } (never the token itself: only its
  # digest is persisted, on the run).
  SESSION_KEY = :db_restore_progress
  # How long the grant opens the progress page without the token in the URL.
  GRANT_TTL = 24.hours

  included do
    prepend_before_action :db_restore_guard
    rescue_from ActiveRecord::AdapterError, with: :db_restore_adapter_error
  end

  class_methods do
    # Lets the given actions through while the lock is held (the progress page only).
    def skip_db_restore_guard(only:)
      skip_before_action(:db_restore_guard, only:)
    end
  end

  private

  def db_restore_guard
    run = DbRestore::Lock.current_run
    return render_db_restore_in_progress(run) if run

    DbRestore::Reconnect.check!
  end

  def db_restore_adapter_error(exception)
    run = DbRestore::Lock.current_run
    raise exception unless run

    render_db_restore_in_progress(run)
  end

  def render_db_restore_in_progress(run)
    if request.format.html? || request.format.to_s == '*/*'
      @db_restore_run = run
      @db_restore_progress_path = db_restore_progress_path_for(run)
      render('db_restore/locked', layout: 'restore', status: :service_unavailable, formats: [:html])
    else
      render(json: { error: 'db_restore_in_progress', run_id: run.id }, status: :service_unavailable)
    end
  end

  # Progress page path of +run+ when this browser holds its grant (it confirmed the run, or opened the token link).
  def db_restore_progress_path_for(run)
    db_restore_progress_granted?(run) ? db_restore_path(run) : nil
  rescue StandardError
    nil
  end

  # Grants this browser the progress page of +run+ for GRANT_TTL (set by the typed confirmation and by a valid token).
  def grant_db_restore_progress!(run)
    session[SESSION_KEY] = { 'run_id' => run.id, 'until' => GRANT_TTL.from_now.utc.iso8601 }
  end

  # True while this browser holds a grant for +run+.
  def db_restore_progress_granted?(run)
    stored = session[SESSION_KEY]
    return false unless stored.is_a?(Hash) && stored['run_id'].to_i == run.id

    expiry = Time.zone.parse(stored['until'].to_s)
    expiry.present? && expiry.future?
  rescue ArgumentError
    false
  end
end
