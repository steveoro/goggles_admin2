# frozen_string_literal: true

require 'digest'

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::Plan
    #
    # The dry run of the clean-up page (0.10.104): what would move, where, and why, for one season. Pure and read-only
    # (it reads the folders, the activity log, the crawler status, the ops DB and the season calendars of the DB;
    # it never writes anything).
    #
    # == Rules (Item#rule)
    # (a) :result_free_source   result-free LT2 of a locally linked meeting with no LT4 working copy and no phase files
    #                           (SeasonBoard::RedundantFiles) => moved to 'results.backup/<season>/cleanup-<timestamp>/'
    #                           (its protected siblings, a '.orig' copy, a commit log, an SQL script, are listed as kept);
    # (b) :pending_manifest     pending manifest PDF (+ '.txt') of a locally linked meeting (its row never asks for an
    #                           extraction then) => archived to manifests.done (PdfManifests::Extraction.archive);
    # (c) :calendar_superseded / :calendar_selection / :calendar_leftover => moved to calendar.done (Sources::CalendarTidy);
    # (d) :duplicate_bases      several sources (file bases) for one FIN id, and :result_pdf, the result PDFs of
    #                           'pdfs/<season>' => LISTED ONLY, never moved: which crawl to keep, and whether a PDF is
    #                           still needed, is the operator's call.
    #
    # == Refusals (Refusal#reason, Sources::Cleanup::REASONS)
    # A file a rule selects is kept (and listed with the reason) when Sources::Cleanup::Safety refuses it: an LT4
    # working copy or phase files on its base, a busy / leased / edited / in-review source, a pending run, a file
    # younger than 10 minutes, a name collision with different content, anything Sources::FileGuard,
    # Sources::FilePolicy or Cleanup.path_refusal refuse; the manifest of a meeting that is NOT linked is the pending
    # input of the structure extraction (:unlinked_meeting). For rule (a) also: an LT2 that can't be parsed
    # (:unreadable_json, it may hold results), an LT2 written by the PDF scan (:pdf_derived), an LT2 changed after the
    # end of the latest crawl recorded for its FIN id (:modified_after_crawl: an edit in the file editor; the activity
    # log keeps only the latest attempt, and without one only the 10-minute rule applies). #blocked_reason refuses the whole run (crawler busy,
    # a crawl queued or running, no ops DB, unreadable activity log).
    #
    # #digest fingerprints the whole plan (blocked reason, items with size and mtime, refusals): Sources::Cleanup::Apply
    # re-plans and refuses when it differs from the one the operator saw.
    #
    class Plan # rubocop:disable Metrics/ClassLength
      RULES = %i[result_free_source pending_manifest calendar_superseded calendar_selection calendar_leftover duplicate_bases result_pdf].freeze
      ACTIONS = %i[move archive list_only].freeze
      LIST_ONLY_RULES = %i[duplicate_bases result_pdf].freeze
      # Tolerance between the mtime of a crawled LT2 and the end of its crawl entry.
      CRAWL_END_TOLERANCE = 2.seconds

      # - path: absolute; relative: to the data root; destination: relative destination path (with
      #   Cleanup::TIMESTAMP_PLACEHOLDER for the run backup folder), nil when listed only;
      # - duplicate: true when an identical copy already sits at the regular destination (the file then goes to the
      #   duplicates folder of the run backup folder); companion: the relative '.txt' moving with a manifest PDF.
      Item = Data.define(:path, :relative, :size, :mtime, :action, :destination, :rule, :fin_event_id, :duplicate, :companion) do
        def initialize(duplicate: false, companion: nil, **) = super

        def movable? = action != :list_only
      end

      Refusal = Data.define(:path, :relative, :reason, :rule, :fin_event_id)

      attr_reader :season_id, :data_root, :now, :safety

      # - safety: a Sources::Cleanup::Safety (default: built for the season); db_index: a SeasonBoard::DbIndex.
      def initialize(season_id:, data_root: Sources.data_root, now: Time.current, safety: nil, db_index: nil)
        @season_id = season_id.to_i
        @data_root = Pathname.new(data_root)
        @now = now
        @safety = safety || Safety.new(season_id: @season_id, data_root: @data_root, now:)
        @db_index = db_index
      end

      def items
        build! unless @items
        @items
      end

      def refusals
        build! unless @refusals
        @refusals
      end

      # Items that move (actions :move and :archive), in apply order.
      def move_items = items.select(&:movable?)

      # Items listed only (duplicate bases, result PDFs).
      def list_items = items.reject(&:movable?)

      # The reason refusing the whole run (Safety#run_refusal), or nil.
      def blocked_reason
        return @blocked_reason if defined?(@blocked_reason)

        @blocked_reason = safety.run_refusal
      end

      def applicable? = blocked_reason.nil? && move_items.any?

      # SHA-256 of the whole plan (see the class notes).
      def digest
        payload = [
          season_id, blocked_reason,
          items.map { |item| [item.rule, item.action, item.relative, item.size, item.mtime.to_i, item.destination, item.companion] },
          refusals.map { |refusal| [refusal.rule, refusal.reason, refusal.relative] }
        ]
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      # Count of the move items per rule ({ rule => n }).
      def counts = move_items.map(&:rule).tally

      delegate :guard, to: :safety
      # (only its read-only #collision is used here: the Plan never moves)
      def mover = @mover ||= Mover.new(guard:, run_folder: RunFolder.new(root: guard.root, season_id:))

      private

      def build!
        @items = []
        @refusals = []
        disk.entries.each_value { |entry| plan_entry(entry) }
        disk.unmatched.each { |entry| entry.manifest_pdf_paths.each { |path| refuse(path, :unlinked_meeting, :pending_manifest, nil) } }
        plan_calendars
        plan_result_pdfs
      end

      def disk
        @disk ||= SeasonBoard::DiskIndex.new(season_id:, data_dir: data_root)
      end

      def db_index
        @db_index ||= SeasonBoard::DbIndex.new(season_id:)
      end

      def linked?(fin_event_id)
        db_index.calendar_for(fin_event_id)&.linked? || false
      end

      # == Rules (a), (b), (d) on one FIN id

      def plan_entry(entry)
        fin_event_id = entry.fin_event_id
        moved_bases = []
        if linked?(fin_event_id)
          busy = safety.fin_refusal(fin_event_id)
          entry.sources.select { |src| SeasonBoard::RedundantFiles.result_free_lt2?(src) }.each do |src|
            moved_bases << src.base if plan_result_free(src, fin_event_id, busy)
          end
          entry.manifest_pdf_paths.each { |path| plan_manifest(path, entry, busy) }
        else
          entry.manifest_pdf_paths.each { |path| refuse(path, :unlinked_meeting, :pending_manifest, fin_event_id) }
        end
        plan_duplicate_bases(entry, moved_bases)
      end

      # Rule (a); true when the LT2 moves.
      def plan_result_free(source, fin_event_id, busy)
        path = source.lt2_path
        reason = SeasonBoard::RedundantFiles.keep_reason(source) || source_refusal(source, source.base, busy) ||
                 safety.file_refusal(path) || modified_after_crawl(path, fin_event_id)
        return refuse(path, reason, :result_free_source, fin_event_id) && false if reason

        add(path, :move, "#{Cleanup.backup_placeholder(season_id)}/#{File.basename(path)}", :result_free_source, fin_event_id:)
        siblings(source.base).each do |sibling|
          refuse(sibling, safety.file_refusal(sibling, check_age: false) || :not_cleanable, :result_free_source, fin_event_id)
        end
        true
      end

      # :modified_after_crawl when the LT2 changed after the end of the latest crawl recorded for the FIN id, outside the
      # run of any crawl recorded in the activity log (an edit in the file editor leaves no other trace on an LT2), else
      # nil. Best effort: the log keeps only the latest attempt of each key (an older crawl run no longer listed reads as
      # an edit: the file is kept), and without a recorded crawl for the FIN id only the 10-minute rule applies.
      def modified_after_crawl(path, fin_event_id)
        finished_at = safety.last_crawl_finished_at(fin_event_id)
        return nil unless finished_at

        mtime = File.mtime(path)
        :modified_after_crawl if mtime > finished_at + CRAWL_END_TOLERANCE && !safety.within_crawl_window?(mtime, tolerance: CRAWL_END_TOLERANCE)
      end

      # The other files of a base that never move with its LT2 (listed as kept).
      def siblings(base)
        dir = disk.results_new_dir
        return [] unless dir.directory?

        quoted = Regexp.escape(base)
        regexp = /\A(?:#{quoted}(?:\.orig(?:-\d+)?\.json|\.committed\.json|-lt4\.log|\.log)|\d+-#{quoted}(?:-lt4)?\.sql)\z/
        dir.children.select { |path| path.file? && regexp.match?(path.basename.to_s) }.map(&:to_s).sort
      end

      # Rule (b).
      def plan_manifest(path, entry, busy)
        base = SeasonBoard::RedundantFiles.manifest_base(path)
        source = entry.sources.find { |src| src.base == base }
        reason = source_refusal(source, base, busy) || safety.file_refusal(path)
        return refuse(path, reason, :pending_manifest, entry.fin_event_id) if reason

        plan_archive(path, entry.fin_event_id)
      end

      # Refusal of every file of a base: an LT4 working copy or phase files on its source (+source+ may be nil), the
      # busy FIN id (+busy+, Safety#fin_refusal), the ops facts of the base (Safety#base_refusal).
      def source_refusal(source, base, busy)
        return :lt4_working_copy if source&.lt4_path
        return :phase_files if source&.phase_paths.present?

        busy || safety.base_refusal(base)
      end

      def plan_archive(path, fin_event_id)
        done_dir = data_root.join('manifests.done', season_id.to_s)
        txt = path.to_s.sub(/\.pdf\z/i, '.txt')
        collisions = [path, txt].select { |file| File.file?(file) }.map { |file| mover.collision(file, done_dir) }
        return refuse(path, :name_collision, :pending_manifest, fin_event_id) if collisions.include?(:different)

        duplicate = collisions.first == :identical
        companion = relative(txt) if File.file?(txt)
        destination = destination_for(path, "manifests.done/#{season_id}", duplicate, 'manifests')
        add(path, :archive, destination, :pending_manifest, fin_event_id:, duplicate:, companion:)
      end

      # Rule (d), first half: the sources still left for the FIN id once rule (a) moved its own.
      def plan_duplicate_bases(entry, moved_bases)
        remaining = entry.sources.select(&:files?).reject { |src| moved_bases.include?(src.base) }
        return unless remaining.many?

        remaining.each { |src| add(src.review_path, :list_only, nil, :duplicate_bases, fin_event_id: entry.fin_event_id) }
      end

      # == Rule (c)

      def plan_calendars
        CalendarTidy.new(season_id:, data_root:, safety:, mover:).candidates.each do |candidate|
          next refuse(candidate.path, candidate.refusal, candidate.rule, nil) if candidate.refusal

          duplicate = candidate.collision == :identical
          add(candidate.path, :move, destination_for(candidate.path, "calendar.done/#{season_id}", duplicate, 'calendar.new'), candidate.rule,
              duplicate:)
        end
      end

      # == Rule (d), second half

      def plan_result_pdfs
        dir = data_root.join('pdfs', season_id.to_s)
        return unless dir.directory?

        dir.children.select { |path| path.file? && path.extname.casecmp?('.pdf') }.sort.each do |path|
          add(path.to_s, :list_only, nil, :result_pdf)
        end
      end

      # == Helpers

      # Relative destination: the regular folder, or the duplicates folder of the run backup folder.
      def destination_for(path, folder, duplicate, origin)
        target = duplicate ? "#{Cleanup.backup_placeholder(season_id)}/#{Cleanup::DUPLICATES_FOLDER}/#{origin}" : folder
        "#{target}/#{File.basename(path.to_s)}"
      end

      # - attributes: fin_event_id, duplicate, companion (Item).
      def add(path, action, destination, rule, **attributes)
        stat = File.stat(path.to_s)
        @items << Item.new(path: path.to_s, relative: relative(path), size: stat.size, mtime: stat.mtime, action:, destination:, rule:,
                           fin_event_id: nil, **attributes)
      rescue SystemCallError
        refuse(path, :missing, rule, attributes[:fin_event_id])
      end

      def refuse(path, reason, rule, fin_event_id)
        @refusals << Refusal.new(path: path.to_s, relative: relative(path), reason:, rule:, fin_event_id:)
      end

      # Lexical path relative to the data root (never follows a link: a link pointing out still shows where it sits).
      def relative(path)
        Pathname.new(path.to_s).relative_path_from(data_root).to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
