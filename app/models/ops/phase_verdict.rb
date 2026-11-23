# frozen_string_literal: true

module Ops
  #
  # = Ops::PhaseVerdict
  #
  # The stored verdict of one Data-Fix phase (1..5) of a source (ops DB, table 'phase_verdicts'), written by
  # DataFix::Pipeline#verdict. Recomputable from the phase files, except +operator_edited_at+, a mirror of the
  # edit marker kept in the phase file '_meta' (the file stays authoritative: wiping ops loses no protection).
  #
  # == Attributes
  # - phase, status (STATUSES), issues_count, issues (capped at ISSUES_CAP), counts, new_entities (capped);
  # - built_by, built_at, built_digest, input_digests: copy of the phase file '_meta.built' stamp;
  # - operator_edited_at, confirmed_count, db_generation (generation the verdict was computed under);
  # - fingerprint: digest of the files/rows the verdict was computed from (cache key), checked_at.
  #
  class PhaseVerdict < ApplicationRecord
    self.table_name = 'phase_verdicts'

    STATUSES = %w[unbuilt clean review blocked stale failed].freeze
    ISSUES_CAP = 200
    NEW_ENTITIES_CAP = 200

    belongs_to :pipeline_source, class_name: 'Ops::PipelineSource', inverse_of: :phase_verdicts

    validates :phase, inclusion: { in: 1..5 }
    validates :status, inclusion: { in: STATUSES }
    validates :phase, uniqueness: { scope: :pipeline_source_id }

    # Caps the issue list (keeps the true count in issues_count).
    def self.capped_issues(issues)
      Array(issues).first(ISSUES_CAP)
    end

    # Caps each new-entities list (e.g. { 'teams' => [...], 'swimmers' => [...] }).
    def self.capped_new_entities(new_entities)
      (new_entities || {}).to_h.transform_values { |list| list.is_a?(Array) ? list.first(NEW_ENTITIES_CAP) : list }
    end
  end
end
