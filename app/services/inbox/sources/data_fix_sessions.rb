# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::DataFixSessions
    #
    # Data-Fix sessions needing attention (DataFix::SessionIndex, any season):
    # - a session idle for IDLE_DAYS days or more whose source still exists => "Resume step N"; since phase 10 the
    #   step comes from the stored verdicts (Ops::PipelineSource#review_phase of a 'needs_review' / 'blocked' source,
    #   opened with the review filter), else the highest phase file; the stored stage is added to the detail;
    # - staging rows whose source file is gone => "Purge staging rows" (DELETE to the sessions list, with confirm).
    # A session also shown by the Season board (same source file) is de-duplicated by Inbox::Builder: the board wins.
    #
    # Key: 'session:<source_path>' and 'session:<source_path>:purge'.
    #
    class DataFixSessions < Inbox::Source
      IDLE_DAYS = 3

      def self.more_path
        Rails.application.routes.url_helpers.data_fix_sessions_path
      end

      # Stored stages that point the resume link at the verdict's review step.
      REVIEW_STAGES = %w[needs_review blocked].freeze

      def items(context)
        index = DataFix::SessionIndex.new(data_dir: context.data_dir)
        rows = index.rows
        sources = pipeline_sources(rows, context)
        rows.filter_map do |row|
          if row.orphan?
            purge_item(row, context)
          elsif row.source_exists? && row.highest_phase.positive? && row.idle_days(context.now).to_i >= IDLE_DAYS
            idle_item(row, context, sources[[row.season_id.to_i, Ops::PipelineSource.base_for(row.source_path)]])
          end
        end
      end

      private

      def idle_item(row, context, source)
        review = source && REVIEW_STAGES.include?(source.stage) && source.review_phase.present?
        phase = review ? source.review_phase : row.highest_phase
        params = { file_path: row.source_path, phase:, filter_state: ('review' if review) }.compact
        next_action = SeasonBoard::NextAction.new(kind: :resume_review, params:)
        item(
          key: "session:#{row.source_path}", kind: :idle_session, band: :notice,
          title: t(:idle_title, name: row.name, days: row.idle_days(context.now)),
          detail: idle_detail(row, source),
          subject: { file_path: row.source_path, season_id: row.season_id }.compact,
          action: action(I18n.t('season_board.actions.resume_review', phase:), SeasonBoard::ActionPaths.link_path(next_action)),
          since: row.mtime
        )
      end

      def idle_detail(row, source)
        detail = t(:idle_detail, season: row.season_id || '-', phase: row.highest_phase, time: short_time(row.mtime))
        stage = source&.stage
        return detail if stage.blank? || stage == 'new'

        "#{detail} · #{I18n.t("pipeline_automation.stages.#{stage}", default: stage)}"
      end

      # Ops::PipelineSource rows of the sessions, by [season_id, base] (one query; {} without the ops DB).
      def pipeline_sources(rows, context)
        return {} unless context.ops_available? && rows.any?

        Ops.safely({}) do
          bases = rows.map { |row| Ops::PipelineSource.base_for(row.source_path) }.uniq
          Ops::PipelineSource.where(base: bases).index_by { |source| [source.season_id.to_i, source.base] }
        end
      end

      def purge_item(row, context)
        confirm = I18n.t('data_import.data_fix.confirm_discard_source', source: row.source_path)
        item(
          key: "session:#{row.source_path}:purge", kind: :orphan_staging, band: :notice,
          title: t(:orphan_title, name: row.name, count: row.staging_rows), detail: t(:orphan_detail, path: row.source_path),
          subject: { file_path: row.source_path, season_id: row.season_id }.compact,
          action: action(t(:purge), url_helpers.data_fix_sessions_purge_path, http_method: :delete, params: { source_path: row.source_path },
                                                                              confirm:),
          since: row.mtime || context.now
        )
      end
    end
  end
end
