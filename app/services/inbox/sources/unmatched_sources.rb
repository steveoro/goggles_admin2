# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::UnmatchedSources
    #
    # Pending files of the board season that match no FIN calendar row (the board summary's
    # +unmatched_sources+, see SeasonBoard::DiskIndex#unmatched):
    # - phase files (:in_review)      => "Resume step N" (Data-Fix review step);
    # - a source to review (:source)  => "Open in Data-Fix" (Phase 1 review);
    # - a manifest PDF only (:manifest) => the Sources Manifests tab of the season.
    # Commit SQL waiting (:sql) is left to the PendingSql source; a source prepared from the Sources page (a pipeline
    # state, phase 15) is left to the pipeline sources (ReadyToCommit, NeedsReview, PrepareFailed), and skipped while
    # its prepare is queued or running.
    #
    # 0.10.102: the summary's +off_board_sources+ (pending files whose FIN id is on no board row: a meeting only on the
    # 'Eventi' calendar, or an adopted link no longer taken) get the same items with their own titles, keyed
    # 'off_board:<fin_event_id>:<base>', so their pending work never vanishes from the dashboard (0.10.103: one prepared
    # from the board's off-board list is left to the pipeline sources, as an unmatched one).
    #
    # Key: 'unmatched:<base>' (and 'off_board:<fin_event_id>:<base>').
    #
    class UnmatchedSources < Inbox::Source
      def self.more_path
        Rails.application.routes.url_helpers.sources_results_path
      end

      def items(context)
        summary = context.board_snapshot
        return [] unless summary

        summary.unmatched_sources.filter_map { |source| item_for(source, summary, context) unless source.pipeline_state } +
          off_board_sources(summary).filter_map { |source| item_for(source, summary, context) unless source.pipeline_state }
      end

      private

      def off_board_sources(summary)
        summary.respond_to?(:off_board_sources) ? Array(summary.off_board_sources) : []
      end

      def item_for(source, summary, context)
        kind, band, target = target_for(source, summary)
        return unless target

        subject = { file_path: source.review_path || source.paths.first, season_id: summary.season_id }.compact
        since = newest_mtime(source.paths) || summary.built_at || context.now
        item(**texts_for(source, kind), kind:, band:, subject:, action: target, since:)
      end

      # [kind, band, Inbox::Action] for the pending kind, or nil.
      def target_for(source, summary)
        case source.pending
        when :in_review
          next_action = SeasonBoard::NextAction.new(kind: :resume_review, params: { file_path: source.review_path, phase: source.phase })
          path = SeasonBoard::ActionPaths.link_path(next_action)
          [:resume_review, :review, action(I18n.t('season_board.actions.resume_review', phase: source.phase), path)] if source.review_path
        when :source
          [:review_source, :review, action(t('actions.review'), url_helpers.review_sessions_path(file_path: source.review_path))] if source.review_path
        when :manifest
          [:manifest, :acquire, action(t('actions.manifests'), url_helpers.sources_manifests_path(season_id: summary.season_id))]
        end
      end

      # Key, title & detail of the item (a source with a FIN id is an off-board one).
      def texts_for(source, kind)
        fin_event_id = source.respond_to?(:fin_event_id) ? source.fin_event_id : nil
        return { key: "unmatched:#{source.base}", title: t("titles.#{kind}", name: source.base), detail: t(:detail) } unless fin_event_id

        { key: "off_board:#{fin_event_id}:#{source.base}", title: t("off_board_titles.#{kind}", name: source.base, fin_event_id:),
          detail: t(:off_board_detail, fin_event_id:) }
      end

      def newest_mtime(paths)
        paths.filter_map { |path| File.mtime(path) if File.exist?(path) }.max
      rescue SystemCallError
        nil
      end
    end
  end
end
