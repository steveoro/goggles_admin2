# frozen_string_literal: true

# SQL Outbox (see Outbox, docs/outbox.md): 'rake ops:rebuild' re-registers the scripts found on disk.
Rails.application.config.to_prepare do
  Ops::Rebuilders.register(:outbox, -> { Outbox::Reconciler.call.counts })
end
