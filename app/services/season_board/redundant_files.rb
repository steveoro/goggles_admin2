# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::RedundantFiles
  #
  # The one rule deciding which crawl outputs of a FIN event id are redundant once its meeting is linked locally
  # (0.10.104), shared by the single-meeting crawl tidy-up (SeasonBoard::CrawlOutput: MeetingCrawlJob, and
  # Sources::CrawlTidy after a Sources crawl) and by the explicit clean-up page (Sources::Cleanup::Plan):
  #
  # - a result-free LT2 source (no result rows, not manifest-derived) with no LT4 working copy and no phase files is
  #   redundant: the structure is already committed and a later crawl brings the results;
  # - a source having an LT4 working copy or phase files is protected: none of its files (the manifest PDF of its base
  #   included) is ever touched;
  # - an LT2 that could not be parsed (truncated, half written: it may hold results) or written by the PDF scan is
  #   never redundant (SourceProbe facts);
  # - the pending manifest PDFs of the other bases of a linked meeting are redundant (its structure is committed).
  #
  # Pure predicates on DiskIndex::Source / DiskIndex::Entry: nothing is read or moved here.
  #
  module RedundantFiles
    module_function

    # True for a result-free LT2 source that the clean-ups may move (see the module notes).
    def removable_source?(source)
      result_free_lt2?(source) && !protected_source?(source) && keep_reason(source).nil?
    end

    # :unreadable_json / :pdf_derived for a result-free LT2 that must stay whatever the rule says, else nil.
    def keep_reason(source)
      return :unreadable_json if source.unparsable?

      :pdf_derived if source.pdf_derived?
    end

    # True for a result-free LT2 source (protected or not).
    def result_free_lt2?(source)
      source.lt2_path.present? && !source.results? && !source.meeting_only?
    end

    # True when the source has an LT4 working copy or phase files: every file of its base stays where it is.
    def protected_source?(source)
      source.lt4_path.present? || source.phase_paths.present?
    end

    # The DiskIndex base of a manifest PDF path ('manifest-<base>.pdf').
    def manifest_base(path)
      File.basename(path.to_s).sub(/\.pdf\z/i, '').delete_prefix('manifest-')
    end

    # Pending manifest PDFs of +entry+ belonging to +bases+, minus those of a protected source.
    def manifests_for(entry, bases)
      protected_bases = entry.sources.select { |src| protected_source?(src) }.map(&:base)
      entry.manifest_pdf_paths.select do |path|
        base = manifest_base(path)
        bases.include?(base) && protected_bases.exclude?(base)
      end
    end
  end
end
