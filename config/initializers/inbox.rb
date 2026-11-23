# frozen_string_literal: true

# Dashboard inbox ("Needs you") sources, in order (see Inbox::Registry and docs/dashboard.md).
# Later phases add theirs here (06: health; 10: ready to commit / needs review / prepare failed) or replace
# one of these (07: Inbox::Registry.replace(:pending_sql, ...); 08: :drift).
Rails.application.config.to_prepare do
  [
    Inbox::Sources::Blockers,
    Inbox::Sources::FailedJobs,
    Inbox::Sources::PendingSql,
    Inbox::Sources::BoardRows,
    Inbox::Sources::UnmatchedSources,
    Inbox::Sources::DataFixSessions,
    Inbox::Sources::FINChange,
    Inbox::Sources::Drift
  ].each { |source| Inbox::Registry.register(source) }
end
