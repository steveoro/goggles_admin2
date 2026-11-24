# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::StateResolver
  #
  # Pipeline state machine of a Season board row: first matching rule wins.
  #
  #  1. :cancelled              row info matches CANCELLED_REGEXP, or the calendar/meeting is cancelled => none
  #  2. :sql_pending            commit SQL for the FIN id waiting in results.new        => :push
  #  3. :prepare_failed         the last Data-Fix prepare failed and the source did not change since
  #                             (detail: { phase:, message: })                          => :prepare ("Retry")
  #  4. :needs_review           stored stage needs_review / blocked (or a "ready" that is no longer current)
  #                             (detail: { step:, count:, blocked: })                   => :resume_review (review filter)
  #  5. :ready_to_commit        every phase verdict clean and fresh (detail: { new_teams:, new_swimmers: }) => :commit
  #  6. :in_review              phase files in results.new without usable verdicts (detail: { phase: N }) => :resume_review
  #  7. :results_ready          source with results in results.new, no phase files      => :review_results
  #  8. :structure_ready        manifest-derived (meeting_only) LT4 in results.new      => :review_structure
  #  9. :manifest_pending       manifest PDF pending, no linked meeting, no archived manifest LT4 => :extract_manifest
  # 10. :committed_with_results linked meeting with results (results_acquired or MIR/MRR > 0) => none
  # 11. :structure_committed    linked meeting without results (detail: { past: bool })
  #                             => :check_results when the row's last date is past, else none
  # 12. :crawled_no_manifest    result-free source in results.new, no manifest PDF, no meeting => :review_header
  # 13. :archived_unlinked      local files exist (archived sources, pushed SQL, extracted PDF) but no linked
  #                             meeting (e.g. committed before the FIN id was stored) => :link
  # 14. :link_not_crawled       FIN id, nothing local => :crawl
  # 15. :not_linked             no URL on the FIN row => none
  #
  # States 3-5 (phase 10) come from the ops pipeline facts (Facts#pipeline, a SeasonBoard::PipelineIndex::Facts
  # filled by the Builder): the resolver itself reads nothing.
  #
  # == NextAction params (Symbol keys; all include :fin_event_id)
  # - :push             => { sql_path: oldest pending SQL path, sql_paths: [all pending SQL paths, sorted] }
  # - :prepare          => { file_path: source path (as for :resume_review) }
  # - :commit           => { file_path: source path } (GET data_fix/commit_summary: the commit is the operator's click)
  # - :resume_review    => { file_path: source path (LT2 when present, else LT4, else the phase file), phase: N
  #                          [, filter_state: 'review' for :needs_review] }
  # - :review_results   => { file_path: LT2 path when present, else the LT4 }
  # - :review_structure => { file_path: meeting_only LT4 path }
  # - :extract_manifest => { pdf_path: }
  # - :check_results    => { url: FIN results URL, meeting_id: }
  # - :review_header    => { file_path: LT2 path when present, else the LT4 }
  # - :link             => { bases: [file base names found on disk] }
  # - :crawl            => { url: FIN results URL }
  #
  class StateResolver
    STATES = %i[
      cancelled sql_pending prepare_failed needs_review ready_to_commit in_review results_ready structure_ready
      manifest_pending committed_with_results structure_committed crawled_no_manifest archived_unlinked
      link_not_crawled not_linked
    ].freeze

    # States owned by the pipeline automation (phase 10; their inbox items come from their own sources).
    PIPELINE_STATES = %i[prepare_failed needs_review ready_to_commit].freeze

    ACTIONS = %i[
      push prepare commit resume_review review_results review_structure extract_manifest check_results review_header link crawl
    ].freeze

    CANCELLED_REGEXP = /annull|rinvi|cancel/i

    # Per-row facts used by the rules:
    # - row: snapshot Hash (String keys); fin_event_id: String|nil; row_date: RowDate;
    # - calendar: DbIndex::CalendarInfo|nil; meeting: DbIndex::MeetingInfo|nil; disk: DiskIndex::Entry|nil;
    # - pipeline: PipelineIndex::Facts|nil (optional, default nil: no ops facts).
    Facts = Data.define(:row, :fin_event_id, :row_date, :calendar, :meeting, :disk, :pipeline) do
      def initialize(pipeline: nil, **) = super
    end

    # Outcome of the resolution.
    Outcome = Data.define(:state, :detail, :next_action)

    def initialize(today: Date.current)
      @today = today
    end

    # Returns an Outcome for the given Facts.
    def call(facts)
      STATES.each do |state|
        result = send(:"rule_#{state}", facts)
        next unless result

        detail, action_kind, params = result
        action = action_kind && NextAction.new(kind: action_kind, params: { fin_event_id: facts.fin_event_id }.merge(params || {}))
        return Outcome.new(state:, detail: detail || {}, next_action: action)
      end
    end

    private

    # == Rules: each returns nil (no match) or [detail Hash, action kind|nil, action params]

    def rule_cancelled(facts)
      return unless CANCELLED_REGEXP.match?(facts.row['info'].to_s) || facts.calendar&.cancelled? || facts.meeting&.cancelled?

      [{}, nil]
    end

    def rule_sql_pending(facts)
      return unless facts.disk&.sql_pending?

      paths = facts.disk.sql_new_paths.sort
      [{ count: paths.size }, :push, { sql_path: paths.first, sql_paths: paths }]
    end

    def rule_prepare_failed(facts)
      pipeline = pipeline_with_source(facts)
      return unless pipeline&.prepare_failed?

      [{ phase: pipeline.failed_phase, message: pipeline.failed_message }, :prepare, { file_path: active_path(facts) }]
    end

    def rule_needs_review(facts)
      pipeline = pipeline_with_source(facts)
      return unless pipeline&.needs_review?

      step = pipeline.review_step
      [{ step:, count: pipeline.review_count, blocked: pipeline.blocked? }, :resume_review,
       { file_path: active_path(facts), phase: step, filter_state: 'review' }]
    end

    def rule_ready_to_commit(facts)
      pipeline = pipeline_with_source(facts)
      return unless pipeline&.ready_to_commit?

      [{ new_teams: pipeline.new_teams, new_swimmers: pipeline.new_swimmers }, :commit, { file_path: active_path(facts) }]
    end

    # The pipeline facts, only when the disk entry still holds the source they describe.
    def pipeline_with_source(facts)
      facts.pipeline if facts.pipeline && active_path(facts)
    end

    # Review path of the source the pipeline facts describe (the review source, else the newest other source).
    def active_path(facts)
      PipelineIndex.active_source(facts.disk)&.review_path
    end

    def rule_in_review(facts)
      source = facts.disk&.review_source
      return unless source

      [{ phase: source.phase }, :resume_review, { file_path: source.review_path, phase: source.phase }]
    end

    def rule_results_ready(facts)
      source = facts.disk&.results_source
      return unless source

      [{}, :review_results, { file_path: source.review_path }]
    end

    def rule_structure_ready(facts)
      source = facts.disk&.structure_source
      return unless source

      [{}, :review_structure, { file_path: source.lt4_path }]
    end

    def rule_manifest_pending(facts)
      disk = facts.disk
      return unless disk&.manifest_pending? && facts.meeting.nil? && !disk.archived_meeting_only?

      [{}, :extract_manifest, { pdf_path: disk.manifest_pdf_path }]
    end

    def rule_committed_with_results(facts)
      return unless facts.meeting&.results?

      [{}, nil]
    end

    def rule_structure_committed(facts)
      return unless facts.meeting
      return [{ past: false }, nil] unless facts.row_date.past?(@today)

      [{ past: true }, :check_results, { url: facts.row['url'].presence, meeting_id: facts.meeting.id }]
    end

    def rule_crawled_no_manifest(facts)
      source = facts.disk&.result_free_source
      return unless source && !facts.disk.manifest_pending?

      [{}, :review_header, { file_path: source.review_path }]
    end

    def rule_archived_unlinked(facts)
      return unless facts.disk&.any_local?

      [{}, :link, { bases: facts.disk.bases }]
    end

    def rule_link_not_crawled(facts)
      return unless facts.fin_event_id

      [{}, :crawl, { url: facts.row['url'] }]
    end

    def rule_not_linked(_facts)
      [{}, nil]
    end
  end
end
