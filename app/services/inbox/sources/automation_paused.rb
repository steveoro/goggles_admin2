# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::AutomationPaused
    #
    # One notice while the pipeline automation is stopped: the master switch 'automation.enabled' is off, or the
    # environment forces it off (ADMIN2_AUTOMATION=0) => opens the switches of the dashboard system column. A
    # sub-switch turned off on purpose (auto-extract, auto-prepare) is shown there only, without an inbox item.
    #
    # Key: 'automation:paused'.
    #
    class AutomationPaused < Inbox::Source
      def items(context)
        env_off = DataFix::Automation.env_off?
        return [] unless env_off || !DataFix::Automation.stored(:enabled)

        [item(
          key: 'automation:paused', kind: :automation_paused, band: :notice, title: t(:title),
          detail: env_off ? t(:detail_env, key: DataFix::Automation::ENV_KEY) : t(:detail_switch),
          action: action(t(:action), "#{url_helpers.root_path}#dashboard-system"), since: paused_since || context.now
        )]
      end

      private

      def paused_since
        Ops.safely do
          next unless Ops.available?

          Ops::Event.where(kind: DataFix::Automation::EVENT_KIND, subject_key: DataFix::Automation::KEYS[:enabled]).maximum(:occurred_at)
        end
      end
    end
  end
end
