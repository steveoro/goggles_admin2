# frozen_string_literal: true

module Drift
  #
  # = Drift::InboxSource
  #
  # The dashboard "Needs you" source of the DB sync check, in the :drift slot of the phase 05 drift v0 source
  # (config/initializers/inbox.rb). Reads only the last stored Ops::DbFingerprint of the configured API:
  # - red   => one 'blocked'-band item (Phase 6 commits are refused until it is solved) opening /db_sync;
  #            (phase 14: plus a "Restore local DB" secondary action opening the restore wizard);
  # - amber => one 'notice'-band item (also a green check older than Ops::DbFingerprint::STALE_AFTER): "Review
  #            remote-only edits" (/remote_writes) when the remote writes are the only reason, else /db_sync;
  # - green, unknown, no check yet => nothing (missing credentials are reported by the blockers source).
  #
  # Key: 'drift' (texts 'inbox.drift.*').
  #
  class InboxSource < Inbox::Source
    def self.key = :drift

    def self.enabled?(context)
      context.ops_available?
    end

    def self.more_path
      Rails.application.routes.url_helpers.db_sync_path
    end

    def items(context)
      fingerprint = Ops::DbFingerprint.latest(context.api_url.to_s)
      return [] unless fingerprint

      case fingerprint.effective_verdict(now: context.now)
      when 'red' then [red_item(fingerprint, context)]
      when 'amber' then [amber_item(fingerprint, context)]
      else []
      end
    end

    private

    def details(fingerprint, context)
      fingerprint.reason_list(now: context.now).first(3).map { |reason| Drift::ReasonText.call(reason) }.join(' · ')
    end

    def red_item(fingerprint, context)
      item(key: 'drift_red', kind: :drift_red, band: :blocked, title: t(:red_title), detail: details(fingerprint, context),
           subject: { api_url: context.api_url, db_fingerprint_id: fingerprint.id },
           action: action(t(:open), url_helpers.db_sync_path), since: fingerprint.taken_at,
           secondary_action: action(t(:restore), url_helpers.new_db_restore_path)) # (14: the guided local DB restore)
    end

    def amber_item(fingerprint, context)
      only_writes = fingerprint.reason_list(now: context.now).pluck(:code).uniq == ['remote_writes']
      path = only_writes ? url_helpers.remote_writes_path : url_helpers.db_sync_path
      item(key: 'drift_amber', kind: :drift_warning, band: :notice, title: t(:amber_title), detail: details(fingerprint, context),
           subject: { api_url: context.api_url, db_fingerprint_id: fingerprint.id },
           action: action(only_writes ? t(:review) : t(:open), path), since: fingerprint.taken_at)
    end
  end
end
