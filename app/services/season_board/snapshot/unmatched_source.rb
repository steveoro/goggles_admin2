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
    # - paths: every pending file (absolute path Strings);
    # - pipeline_state (phase 15): :preparing, :prepare_failed, :needs_review or :ready_to_commit for a source prepared
    #   from the Sources page (nil otherwise), with its pipeline_detail Hash (Symbol keys, see SeasonBoard::StateText).
    #
    UnmatchedSource = Data.define(:base, :bases, :pending, :review_path, :phase, :paths, :pipeline_state, :pipeline_detail) do
      def initialize(pipeline_state: nil, pipeline_detail: {}, **) = super

      # Builds the UnmatchedSource from its stored Hash (String keys).
      def self.from_payload(hash)
        pipeline = hash['pipeline'].is_a?(Hash) ? hash['pipeline'] : {}
        new(
          base: hash['base'], bases: Array(hash['bases']), pending: hash['pending'].presence&.to_sym,
          review_path: hash['review_path'], phase: hash['phase'], paths: Array(hash['paths']),
          pipeline_state: pipeline['state'].presence&.to_sym, pipeline_detail: pipeline['detail'].to_h.symbolize_keys
        )
      end

      def manifest_only? = pending == :manifest

      # True while a prepare of the source is queued or running.
      def preparing? = pipeline_state == :preparing
    end
  end
end
