# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Preserver
  #
  # What a restore keeps of the local-only MySQL state (a production dump replaces 'settings', 'app_parameters' and
  # 'users'). Captured right before the drop, re-applied by DbRestore::PostSteps:
  # - the API URL (framework_urls.api): kept by default ('api_url_choice' 'keep'), or the dump's ('dump');
  # - the operator's JWT (users.jwt of the run's user): stored in the ops row only until it is re-applied or the run
  #   ends (Ops::RestoreRun drops it on every terminal status); every statement carrying it runs with the SQL log
  #   silenced, and 'preserved' is a filtered attribute (inspect, logged binds);
  # The session needs nothing (ops DB, Ops::SessionStoreSetup); the ops DB and the crawler files are not touched.
  #
  module Preserver
    CHOICES = %w[keep dump].freeze

    module_function

    # Reads the values from the current (pre-restore) MySQL DB into run.preserved. A resumed run keeps the values
    # captured the first time (MySQL may be half loaded by then).
    def capture!(run)
      return run.preserved if run.preserved.to_h['captured_at'].present?

      user = run.user_id && GogglesDb::User.find_by(id: run.user_id)
      preserved = run.preserved.to_h.merge(
        'api_url' => APIProxy.configured_base_url.to_s.strip.presence,
        'api_url_choice' => choice(run),
        'user_id' => run.user_id,
        'jwt' => user&.jwt.presence,
        'captured_at' => Time.current.utc.iso8601
      )
      DbRestore.without_sql_log { run.update!(preserved:) }
      preserved
    end

    # Re-applies the preserved values to the restored DB; returns { 'api_url' => ..., 'jwt' => ... } outcomes.
    def reapply!(run)
      preserved = run.preserved.to_h
      outcome = { 'api_url' => reapply_api_url!(preserved), 'jwt' => reapply_jwt!(preserved) }
      run.update!(preserved: preserved.except('jwt').merge('jwt_reapplied_at' => Time.current.utc.iso8601)) if outcome['jwt'] == 'applied'
      outcome
    end

    def choice(run)
      value = run.confirmations.to_h['api_url_choice'].to_s
      CHOICES.include?(value) ? value : 'keep'
    end

    def reapply_api_url!(preserved)
      return 'dump' if preserved['api_url_choice'] == 'dump'
      return 'none' if preserved['api_url'].blank?

      cfg = GogglesDb::AppParameter.config
      cfg.settings(:framework_urls).value['api'] = preserved['api_url']
      cfg.save!
      'kept'
    end

    def reapply_jwt!(preserved)
      return 'none' if preserved['user_id'].blank? || preserved['jwt'].blank?

      updated = DbRestore.without_sql_log do
        GogglesDb::User.where(id: preserved['user_id']).update_all(jwt: preserved['jwt']) # rubocop:disable Rails/SkipsModelValidations
      end
      updated.positive? ? 'applied' : 'user_missing'
    end
  end
end
