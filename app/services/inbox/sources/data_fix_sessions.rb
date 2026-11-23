# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::DataFixSessions
    #
    # Data-Fix sessions needing attention (DataFix::SessionIndex, any season):
    # - a session idle for IDLE_DAYS days or more whose source still exists => "Resume step N";
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

      def items(context)
        index = DataFix::SessionIndex.new(data_dir: context.data_dir)
        index.rows.filter_map do |row|
          if row.orphan?
            purge_item(row, context)
          elsif row.source_exists? && row.highest_phase.positive? && row.idle_days(context.now).to_i >= IDLE_DAYS
            idle_item(row, context)
          end
        end
      end

      private

      def idle_item(row, context)
        next_action = SeasonBoard::NextAction.new(kind: :resume_review, params: { file_path: row.source_path, phase: row.highest_phase })
        item(
          key: "session:#{row.source_path}", kind: :idle_session, band: :notice,
          title: t(:idle_title, name: row.name, days: row.idle_days(context.now)),
          detail: t(:idle_detail, season: row.season_id || '-', phase: row.highest_phase, time: short_time(row.mtime)),
          subject: { file_path: row.source_path, season_id: row.season_id }.compact,
          action: action(I18n.t('season_board.actions.resume_review', phase: row.highest_phase), SeasonBoard::ActionPaths.link_path(next_action)),
          since: row.mtime
        )
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
