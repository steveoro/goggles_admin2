# frozen_string_literal: true

# Dashboard inbox ("Needs you") sources, in order (see Inbox::Registry and docs/dashboard.md).
# Later phases add theirs here (06: health; 10: ready to commit / needs review / prepare failed / ...) or replace
# one of these (07: Inbox::Registry.replace(:pending_sql, ...)).
Rails.application.config.to_prepare do
  [
    Inbox::Sources::Blockers,
    Inbox::Sources::FailedJobs,
    Inbox::Sources::PendingSql,
    Inbox::Sources::BoardRows,
    Inbox::Sources::UnmatchedSources,
    Inbox::Sources::DataFixSessions,
    Inbox::Sources::FINChange,
    Inbox::Sources::FINNotice, # (0.10.103: the FIN changes acknowledged with nothing to crawl, until dismissed)
    Drift::InboxSource, # (key :drift; 08: the DB fingerprint verdict took the slot of the 05 drift v0 source)
    Health::InboxSource, # (key :health: data health errors per season & group, failed runs, overdue sweep)
    # 10: the pipeline automation (board rows in its states, the given-up extractions, the paused switches)
    Inbox::Sources::ReadyToCommit,
    Inbox::Sources::NeedsReview,
    Inbox::Sources::PrepareFailed,
    Inbox::Sources::ExtractionGaveUp,
    Inbox::Sources::AutomationPaused
  ].each { |source| Inbox::Registry.register(source) }

  # 07: the SQL Outbox registry replaces the disk-derived pending SQL list in the same slot
  # (Outbox::InboxSource falls back to Inbox::Sources::PendingSql when the ops DB is not available).
  Inbox::Registry.replace(:pending_sql, Outbox::InboxSource)
end
