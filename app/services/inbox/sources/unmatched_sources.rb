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
    # - a manifest PDF only (:manifest) => the Result files page (until phase 15 adds a better target).
    # Commit SQL waiting (:sql) is left to the PendingSql source.
    #
    # Key: 'unmatched:<base>'.
    #
    class UnmatchedSources < Inbox::Source
      def self.more_path
        Rails.application.routes.url_helpers.pull_result_files_path
      end

      def items(context)
        summary = context.board_snapshot
        return [] unless summary

        summary.unmatched_sources.filter_map { |source| item_for(source, summary, context) }
      end

      private

      def item_for(source, summary, context)
        kind, band, target = target_for(source)
        return unless target

        item(
          key: "unmatched:#{source.base}", kind:, band:,
          title: t("titles.#{kind}", name: source.base), detail: t(:detail),
          subject: { file_path: source.review_path || source.paths.first, season_id: summary.season_id }.compact,
          action: target, since: newest_mtime(source.paths) || summary.built_at || context.now
        )
      end

      # [kind, band, Inbox::Action] for the pending kind, or nil.
      def target_for(source)
        case source.pending
        when :in_review
          next_action = SeasonBoard::NextAction.new(kind: :resume_review, params: { file_path: source.review_path, phase: source.phase })
          path = SeasonBoard::ActionPaths.link_path(next_action)
          [:resume_review, :review, action(I18n.t('season_board.actions.resume_review', phase: source.phase), path)] if source.review_path
        when :source
          [:review_source, :review, action(t('actions.review'), url_helpers.review_sessions_path(file_path: source.review_path))] if source.review_path
        when :manifest
          [:manifest, :acquire, action(t('actions.result_files'), url_helpers.pull_result_files_path)]
        end
      end

      def newest_mtime(paths)
        paths.filter_map { |path| File.mtime(path) if File.exist?(path) }.max
      rescue SystemCallError
        nil
      end
    end
  end
end
