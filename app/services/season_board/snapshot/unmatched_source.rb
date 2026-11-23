# frozen_string_literal: true

module SeasonBoard
  class Snapshot
    #
    # = SeasonBoard::Snapshot::UnmatchedSource
    #
    # Pending local files not matched to any FIN calendar row (DiskIndex#unmatched), rebuilt from a
    # stored summary (see SeasonBoard::Snapshot):
    #
    # - base: first file base name; bases: all of them (Strings);
    # - pending: :in_review (phase files), :source (a source to review), :sql (commit SQL to push)
    #   or :manifest (only a manifest PDF to extract);
    # - review_path: file to open in the Data-Fix review (review_sessions_path(file_path:)), nil for
    #   :sql and :manifest; phase: highest phase file number (or nil);
    # - paths: every pending file (absolute path Strings).
    #
    UnmatchedSource = Data.define(:base, :bases, :pending, :review_path, :phase, :paths) do
      # Builds the UnmatchedSource from its stored Hash (String keys).
      def self.from_payload(hash)
        new(
          base: hash['base'], bases: Array(hash['bases']), pending: hash['pending'].presence&.to_sym,
          review_path: hash['review_path'], phase: hash['phase'], paths: Array(hash['paths'])
        )
      end

      def manifest_only? = pending == :manifest
    end
  end
end
