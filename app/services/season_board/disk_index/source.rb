# frozen_string_literal: true

module SeasonBoard
  class DiskIndex
    # A source pending in results.new (all paths absolute Strings, or nil):
    # - lt2_path: '<base>.json' with LT2 data;
    # - lt4_path: LT4 working copy / manifest-derived file / LT4-content '<base>.json';
    # - has_results: true when any of the two carries result rows;
    # - meeting_only: true when the LT4 file is manifest-derived ('_meta.meeting_only');
    # - phase: highest existing phase number (nil when none); phase_paths: { N => path };
    # - mtime: most recent modification time among the files.
    Source = Data.define(:base, :lt2_path, :lt4_path, :has_results, :meeting_only, :phase, :phase_paths, :mtime) do
      # Path to hand to the Data-Fix review actions: the LT2 when present (so that the working
      # copy is resolved/re-materialized by DataFix::SourceResolver), else the LT4, else the
      # highest phase file (its meta points back to the source).
      def review_path
        lt2_path || lt4_path || phase_paths[phase]
      end

      def results? = has_results
      def meeting_only? = meeting_only
      def in_review? = phase.present?
      def files? = lt2_path.present? || lt4_path.present?
    end
  end
end
