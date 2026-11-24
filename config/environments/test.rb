# frozen_string_literal: true

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  config.enable_reloading = false
  config.action_view.cache_template_loading = true

  # Do not eager load code on boot. This avoids loading your whole application
  # just for the purpose of running a single test. If you are using a tool that
  # preloads Rails for running tests, you may have to set it to true.
  config.eager_load = false

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.hour.to_i}"
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Raise exceptions instead of rendering exception templates.
  config.action_dispatch.show_exceptions = :none

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  config.action_mailer.perform_caching = false

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test
  # Allow usage of "have_enqueued_job.on_queue(...)" during tests:
  config.active_job.queue_adapter = :test
  # Keep the FIN page watcher state separate from the development one (see FedernuotoWatch::StateStore):
  config.x.federnuoto_watch.state_path = Rails.root.join('tmp/federnuoto-watch.test.json')
  config.x.season_board.activity_log_path = Rails.root.join('tmp/season-board.test.json')
  # Local crawler status & PID files read by SystemStatus::CrawlerProbe (never the developer's real ones):
  config.x.crawler.status_path = Rails.root.join('tmp/crawler-status.test.json')
  config.x.crawler.pid_path = Rails.root.join('tmp/pids/crawler.test.pid')
  # Action Mailer default URL, required by Devise:
  config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr
  config.active_support.report_deprecations = false

  # Raises error for missing translations.
  # Missing translations (views and I18n.t) must fail the suite:
  config.i18n.raise_on_missing_translations = true

  # GogglesDb's Localizable probes the optional '<scope>.alt_label_<code>' / 'long_label_<code>'
  # keys and falls back to the default label when they are missing: keep those probes non-raising.
  config.after_initialize do
    strict_handler = I18n.exception_handler
    I18n.exception_handler = lambda do |exception, locale, key, options|
      if exception.is_a?(I18n::MissingTranslation) && key.to_s.match?(/(?:\A|\.)(?:alt|long)_label_[^.]+\z/)
        "translation missing: #{locale}.#{key}"
      else
        strict_handler.call(exception, locale, key, options)
      end
    end
  end

  # ============================================================================
  # Bullet gem specific configuration:
  # ============================================================================
  # (see https://github.com/flyerhzm/bullet)
  config.after_initialize do
    Bullet.enable = true
    Bullet.bullet_logger = true
    Bullet.raise = true # raise an error if n+1 query occurs
    # Bullet.stacktrace_includes = ['goggles_db']

    # Detect eager-loaded associations which are not used
    Bullet.unused_eager_loading_enable = false
  end
end
