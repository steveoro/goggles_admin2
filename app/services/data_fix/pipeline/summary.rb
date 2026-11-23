# frozen_string_literal: true

module DataFix
  class Pipeline
    #
    # = DataFix::Pipeline::Summary
    #
    # Per-phase verdicts of a source plus its overall stage (read by the stepper, the commit summary, the board):
    # - stage: 'failed' (a build raised), 'blocked' (a commit would fail, or the source changed under edits),
    #   'needs_review' (a phase in review, stale or not built yet), 'ready_to_commit', 'new' (nothing built);
    # - review_phase: the first phase needing attention; ready?: the ready rule of DataFix::ReviewRules.
    #
    Summary = Data.define(:verdicts, :stage, :review_phase, :source_changed, :source_details, :result_free, :source_kind) do
      def self.build(pipeline:, verdicts:)
        row = pipeline.source_row
        source_changed = row&.source_changed_under_edits? || false
        result_free = pipeline.result_free?
        stage, review_phase = stage_for(verdicts, source_changed:)
        new(verdicts:, stage:, review_phase:, source_changed:, source_details: row&.stage_details || {},
            result_free:, source_kind: source_kind_for(pipeline, result_free))
      end

      def self.stage_for(verdicts, source_changed:) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        ordered = verdicts.sort_by(&:first).map(&:last)
        return ['blocked', ordered.find(&:blocked?)&.phase || 1] if source_changed
        return ['failed', ordered.find(&:failed?).phase] if ordered.any?(&:failed?)
        return ['new', 1] if ordered.all?(&:unbuilt?)
        return ['blocked', ordered.find(&:blocked?).phase] if ordered.any?(&:blocked?)

        attention = ordered.find { |verdict| !verdict.clean? }
        return ['needs_review', attention.phase] if attention

        ['ready_to_commit', nil]
      end

      def self.source_kind_for(pipeline, result_free)
        return 'manifest' if pipeline.source_json.dig('_meta', 'meeting_only') == true
        return 'result_free' if result_free

        'results'
      end

      def [](phase) = verdicts[phase.to_i]

      def ready? = stage == 'ready_to_commit'

      def review_count
        verdicts.values.sum { |verdict| verdict.review_issues.sum { |issue| [issue['count'].to_i, 1].max } }
      end

      def new_teams = Array(verdicts[2]&.new_teams)
      def new_swimmers = Array(verdicts[3]&.new_swimmers)
    end
  end
end
