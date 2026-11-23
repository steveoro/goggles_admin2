# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::PendingSql
    #
    # SQL scripts waiting to be pushed: 'NNNN-*.sql' files in <data_dir>/results.new/<numeric season>/ and
    # <data_dir>/results.new/misc/ (commit batches and Season board scripts alike), sorted by their numeric
    # prefix, as ONE grouped item ("N scripts to push, oldest NNNN") opening the Push page on the oldest
    # script's folder (order matters).
    #
    # Phase 07 replaces this source (Inbox::Registry.replace(:pending_sql, ...)) with one reading the outbox.
    #
    # Key: 'pending_sql'.
    #
    class PendingSql < Inbox::Source
      SCRIPT_REGEXP = /\A(?<number>\d+)-.+\.sql\z/
      FOLDER_REGEXP = /\A(\d+|misc)\z/

      def self.more_path
        Rails.application.routes.url_helpers.push_index_path
      end

      def items(context)
        scripts = pending_scripts(context.data_dir)
        return [] if scripts.empty?

        oldest = scripts.first
        number = SCRIPT_REGEXP.match(File.basename(oldest))[:number]
        [item(
          key: 'pending_sql', kind: :push, band: :push, count: scripts.size,
          title: t(:title, count: scripts.size, number:),
          detail: scripts.first(3).map { |path| File.basename(path) }.join(', ') + (scripts.size > 3 ? ', ...' : ''),
          subject: { sql_path: oldest },
          action: action(t(:push), url_helpers.push_index_path(SeasonBoard::ActionPaths.push_folder_params(oldest))),
          since: mtime_of(oldest) || context.now
        )]
      end

      private

      # Pending script paths, oldest (lowest numeric prefix) first.
      def pending_scripts(data_dir)
        Dir.glob(data_dir.join('results.new', '*', '[0-9]*.sql').to_s)
           .select { |path| FOLDER_REGEXP.match?(File.basename(File.dirname(path))) && SCRIPT_REGEXP.match?(File.basename(path)) }
           .sort_by { |path| [SCRIPT_REGEXP.match(File.basename(path))[:number].to_i, File.basename(path)] }
      end

      def mtime_of(path)
        File.mtime(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
