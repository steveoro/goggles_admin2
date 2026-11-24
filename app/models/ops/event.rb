# frozen_string_literal: true

module Ops
  #
  # = Ops::Event
  #
  # Append-only event log row (ops DB, table 'events'). Write it only through Ops.record_event!.
  # The display text comes from the 'ops.events.<kind>' i18n keys.
  #
  class Event < ApplicationRecord
    self.table_name = 'events'

    validates :kind, :occurred_at, presence: true
    validates :level, inclusion: { in: Ops::EVENT_LEVELS }
    validates :actor, inclusion: { in: Ops::EVENT_ACTORS }

    scope :recent, -> { order(occurred_at: :desc, id: :desc) }
    scope :of_kind, ->(kind) { where(kind:) }
    scope :for_subject, ->(type, key) { where(subject_type: type, subject_key: key.to_s) }

    # Localized label for the kind (falls back to the kind itself).
    def title
      I18n.t("ops.events.#{kind}", default: kind)
    end
  end
end
