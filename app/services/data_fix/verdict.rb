# frozen_string_literal: true

module DataFix
  #
  # = DataFix::Verdict
  #
  # The checkable outcome of one Data-Fix phase of a source (computed by DataFix::Verdicts::Phase1..5 through
  # DataFix::Pipeline#verdict, stored in Ops::PhaseVerdict).
  #
  # == Statuses (STATUSES)
  # - unbuilt: no phase file yet;
  # - clean: nothing to decide, the commit would not fail because of this phase;
  # - review: an operator decision is needed;
  # - blocked: the commit would fail (or a guard refuses it);
  # - stale: an upstream input changed after the build (see DataFix::Pipeline#stale?);
  # - failed: the last build raised (+message+ holds the error).
  #
  # == Members
  # - issues: Array of Hashes { 'code', 'level' ('blocked'|'review'|'stale'|'info'), 'message', 'count' };
  # - counts: Hash of phase counters (e.g. 'teams', 'new', 'review');
  # - new_entities: { 'teams' => [...], 'swimmers' => [...] } (confidently new, listed by the commit summary);
  # - edited / adopted: edit marker flags (adopted = pre-existing file, protected as edited);
  # - stale_reasons: [{ 'upstream' => 2, 'what' => 'team ids', 'key' => 'p2' }];
  # - built_by, built_at, message.
  #
  Verdict = Data.define(:phase, :status, :issues, :counts, :new_entities, :edited, :adopted, :stale_reasons,
                        :built_by, :built_at, :message) do
    # Precedence when several statuses apply (first wins).
    const_set(:STATUSES, %w[unbuilt clean review blocked stale failed].freeze)
    const_set(:PRECEDENCE, %w[failed stale blocked review clean unbuilt].freeze)

    def self.build(phase:, status: 'clean', issues: [], counts: {}, new_entities: {}, edited: false, adopted: false,
                   stale_reasons: [], built_by: nil, built_at: nil, message: nil)
      new(phase:, status: status.to_s, issues: Array(issues), counts: counts || {}, new_entities: new_entities || {},
          edited:, adopted:, stale_reasons: Array(stale_reasons), built_by:, built_at:, message:)
    end

    # Status from the issue levels: blocked > review > clean.
    def self.status_for(issues)
      levels = Array(issues).map { |issue| issue['level'].to_s }
      return 'blocked' if levels.include?('blocked')
      return 'review' if levels.include?('review')

      'clean'
    end

    def self.from_row(row)
      build(phase: row.phase, status: row.status, issues: row.issues, counts: row.counts,
            new_entities: row.new_entities, edited: row.counts.to_h['_edited'] == true,
            adopted: row.counts.to_h['_adopted'] == true, stale_reasons: row.counts.to_h['_stale_reasons'],
            built_by: row.built_by, built_at: row.built_at, message: row.counts.to_h['_message'])
    end

    def unbuilt? = status == 'unbuilt'
    def clean? = status == 'clean'
    def review? = status == 'review'
    def blocked? = status == 'blocked'
    def stale? = status == 'stale'
    def failed? = status == 'failed'

    def issues_count
      issues.sum { |issue| [issue['count'].to_i, 1].max }
    end

    def blocking_issues = issues.select { |issue| issue['level'] == 'blocked' }
    def review_issues = issues.select { |issue| issue['level'] == 'review' }

    def new_teams = Array(new_entities['teams'])
    def new_swimmers = Array(new_entities['swimmers'])

    # Counts stored on the ops row (with the flags the row has no column for).
    def counts_for_row
      counts.merge('_edited' => edited, '_adopted' => adopted, '_stale_reasons' => stale_reasons, '_message' => message)
    end
  end
end
