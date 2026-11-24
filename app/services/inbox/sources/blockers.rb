# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::Blockers
    #
    # Band-0 items: conditions that stop the work altogether.
    # - API-offline session (no valid JWT for the configured API) => "Open Settings";
    # - no valid background credentials (Ops::BackgroundCredentials: the KPI and drift jobs make no call)
    #   => "Sign in again" (skipped in an API-offline session: fix the API first);
    # - local ops DB not ready => setup instructions (docs);
    # - no live Solid Queue process (SystemStatus::QueueProbe at :error) => how to start the jobs (docs).
    #
    # Keys: 'blocker:api_offline', 'blocker:credentials', 'blocker:ops_db', 'blocker:queue'.
    #
    class Blockers < Inbox::Source
      DOCS_URL = 'https://github.com/steveoro/goggles_admin2/blob/main/docs/dashboard.md'

      def items(context)
        [api_offline_item(context), credentials_item(context), ops_item(context), queue_item(context)].compact
      end

      private

      def api_offline_item(context)
        return unless context.api_offline?

        blocker(:api_offline, context, detail: t('api_offline.detail', url: context.api_url.presence || '-'),
                                       action: action(t('api_offline.action'), url_helpers.settings_path))
      end

      def credentials_item(context)
        return if context.api_offline? || !context.ops_available?

        status = Ops::BackgroundCredentials.status
        return if status == :valid

        blocker(:credentials, context, detail: t("credentials.#{status}"),
                                       action: action(t('credentials.action'), url_helpers.destroy_user_session_path, http_method: :delete))
      end

      def ops_item(context)
        return if context.ops_available?

        state = Ops.state
        blocker(:ops_db, context, detail: t('ops_db.detail', state: I18n.t("ops.setup_notice.states.#{state}", default: state.to_s)),
                                  action: action(t('ops_db.action'), "#{DOCS_URL}#local-ops-db"))
      end

      def queue_item(context)
        result = SystemStatus::QueueProbe.new(now: context.now).call
        return unless result.level == :error

        blocker(:queue, context, detail: result.detail, action: action(t('queue.action'), "#{DOCS_URL}#background-jobs"))
      end

      def blocker(kind, context, detail:, action:)
        item(key: "blocker:#{kind}", kind:, band: :blocked, title: t("#{kind}.title"), detail:, action:, since: context.now)
      end
    end
  end
end
