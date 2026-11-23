# frozen_string_literal: true

module Outbox
  #
  # = Outbox::InboxSource
  #
  # The dashboard "Needs you" source of the SQL Outbox, registered in the slot of the phase 05 source
  # (<tt>Inbox::Registry.replace(:pending_sql, Outbox::InboxSource)</tt>, config/initializers/inbox.rb).
  # Reads Outbox::Summary only (read only, two queries):
  # - in-doubt pushes        => one 'failed'-band item (they need a decision by hand);
  # - scripts to push        => one grouped 'push'-band item opening the Outbox on the oldest pending script;
  # - only held scripts left => one 'notice'-band item.
  # With the ops DB not available it falls back to the disk-derived list (Inbox::Sources::PendingSql).
  #
  # Key: 'pending_sql' (texts 'inbox.pending_sql.*').
  #
  class InboxSource < Inbox::Source
    def self.key = :pending_sql

    def self.more_path
      Rails.application.routes.url_helpers.outbox_path
    end

    def items(context)
      return Inbox::Sources::PendingSql.new.items(context) unless context.ops_available?

      summary = Outbox::Summary.call
      return [] if summary.nil?

      [in_doubt_item(summary, context), pending_item(summary, context), held_item(summary, context)].compact
    end

    private

    def in_doubt_item(summary, context)
      return if summary.in_doubt.zero?

      first = Ops::SqlScript.in_doubt.ordered.first
      item(key: 'outbox_in_doubt', kind: :push_in_doubt, band: :failed, count: summary.in_doubt,
           title: t(:in_doubt, count: summary.in_doubt), detail: first&.filename,
           subject: { sql_script_id: first&.id }, action: action(t(:resolve), url_helpers.outbox_path(focus: first&.filename)),
           since: first&.updated_at || context.now)
    end

    def pending_item(summary, context) # rubocop:disable Metrics/AbcSize
      oldest = summary.oldest_pending
      return unless oldest

      names = Ops::SqlScript.pending.ordered.limit(3).pluck(:filename)
      detail = names.join(', ') + (summary.pending > 3 ? ', ...' : '')
      detail += " (#{t(:held, count: summary.held)})" if summary.held.positive?
      item(key: 'pending_sql', kind: :push, band: :push, count: summary.pending,
           title: t(:title, count: summary.pending, number: format('%04d', oldest.seq)), detail:,
           subject: { sql_path: oldest.absolute_path.to_s, sql_script_id: oldest.id },
           action: action(t(:push), url_helpers.outbox_path(focus: oldest.filename)),
           since: oldest.created_at || context.now)
    end

    def held_item(summary, context)
      return if summary.held.zero? || summary.pending.positive?

      first = Ops::SqlScript.held.ordered.first
      item(key: 'outbox_held', kind: :held_sql, band: :notice, count: summary.held,
           title: t(:held_only, count: summary.held), detail: first&.filename, subject: { sql_script_id: first&.id },
           action: action(t(:open), url_helpers.outbox_path(focus: first&.filename)), since: first&.updated_at || context.now)
    end
  end
end
