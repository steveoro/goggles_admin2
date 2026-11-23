# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::Drift
    #
    # Drift v0 warning for the configured API (Drift::V0Status: the 'drift_v0:<api_url>' snapshot plus the live
    # count of the unacknowledged remote writes) => "Review remote-only edits" (/remote_writes). Only the :warn
    # level makes an item. Phase 08 replaces this source with one reading the DB fingerprints.
    #
    # Key: 'drift_v0'.
    #
    class Drift < Inbox::Source
      def self.enabled?(context)
        context.ops_available?
      end

      def items(context)
        status = ::Drift::V0Status.for(context.api_url, now: context.now)
        return [] unless status.warn?

        [item(
          key: 'drift_v0', kind: :drift_warning, band: :notice,
          title: t(:title), detail: status.details.join(' · '), subject: { api_url: context.api_url },
          action: action(t(:review), url_helpers.remote_writes_path), since: status.checked_at || context.now
        )]
      end
    end
  end
end
