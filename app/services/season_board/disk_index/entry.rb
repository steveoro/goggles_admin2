# frozen_string_literal: true

module SeasonBoard
  class DiskIndex
    # All the files found for a FIN event id (or for a single base name without FIN id).
    # Paths are absolute Strings.
    class Entry
      attr_reader :fin_event_id, :bases, :sources, :manifest_pdf_paths, :manifest_done_paths,
                  :archived_paths, :sql_new_paths, :sql_sent_paths

      def initialize(fin_event_id)
        @fin_event_id = fin_event_id
        @bases = []
        @sources = []
        @manifest_pdf_paths = []
        @manifest_done_paths = []
        @archived_paths = []
        @archived_meeting_only = false
        @sql_new_paths = []
        @sql_sent_paths = []
      end

      # Highest phase number among the sources in review (or nil).
      def phase
        review_source&.phase
      end

      # Source with the highest phase file (or nil).
      def review_source
        sources.select(&:in_review?).max_by { |src| [src.phase, src.mtime.to_f] }
      end

      # Most recent source carrying results (or nil).
      def results_source
        latest(sources.select { |src| src.results? && src.files? })
      end

      # Most recent manifest-derived (meeting_only) result-free source (or nil).
      def structure_source
        latest(sources.select { |src| src.meeting_only? && !src.results? && src.lt4_path })
      end

      # Most recent result-free source which is not manifest-derived (or nil).
      def result_free_source
        latest(sources.select { |src| !src.results? && !src.meeting_only? && src.files? })
      end

      # Oldest pending manifest PDF (or nil).
      def manifest_pdf_path
        manifest_pdf_paths.min
      end

      def manifest_pending? = manifest_pdf_paths.any?
      def sql_pending? = sql_new_paths.any?
      def archived? = archived_paths.any?

      # True when a manifest-derived (meeting_only) LT4 was archived in results.done.
      def archived_meeting_only? = @archived_meeting_only

      # True when something is pending in results.new or manifests (i.e. not just history).
      def pending?
        sources.any? || sql_pending? || manifest_pending?
      end

      # True when any file at all is known for this entry.
      def any_local?
        pending? || archived? || sql_sent_paths.any? || manifest_done_paths.any?
      end

      # == Builder helpers (used by DiskIndex)

      def add_base(base)
        @bases << base unless @bases.include?(base)
      end

      def mark_archived_meeting_only!
        @archived_meeting_only = true
      end

      private

      def latest(list)
        list.max_by { |src| src.mtime.to_f }
      end
    end
  end
end
