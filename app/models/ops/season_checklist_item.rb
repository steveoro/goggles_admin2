# frozen_string_literal: true

module Ops
  #
  # = Ops::SeasonChecklistItem
  #
  # The operator's state of one step of the season-start checklist (ops DB, table 'season_checklist_items', phase 13;
  # see Maintenance::SeasonStart::Checklist): +status+ (pending | done | skipped), +note+, +done_by+ (user id),
  # +done_at+ and the +operation_run_id+ of the step's operation, when it has one. Unique per (season_id, step_key).
  # The steps whose state is read from data (Season rows, CategoryTypes, the standard-timings file, the remote season,
  # the board season) re-derive it on every view: a row there only records who confirmed, skipped or released what.
  #
  class SeasonChecklistItem < ApplicationRecord
    self.table_name = 'season_checklist_items'

    STATUSES = %w[pending done skipped].freeze

    validates :season_id, :step_key, presence: true
    validates :step_key, uniqueness: { scope: :season_id }
    validates :status, inclusion: { in: STATUSES }

    scope :for_season, ->(season_id) { where(season_id:) }

    def done? = status == 'done'
    def skipped? = status == 'skipped'
    def pending? = status == 'pending'

    # The row of (season_id, step_key), new when missing.
    def self.for_step(season_id, step_key)
      find_or_initialize_by(season_id:, step_key: step_key.to_s)
    end
  end
end
