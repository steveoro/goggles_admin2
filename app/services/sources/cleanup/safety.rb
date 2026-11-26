# frozen_string_literal: true

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::Safety
    #
    # The "is it safe to move?" checks shared by every clean-up flow (0.10.104): SeasonBoard::CrawlOutput (the board
    # crawl tidy-up, also run by Sources::CrawlTidy), Sources::CalendarTidy, Sources::Cleanup::Plan and, item by item,
    # Sources::Cleanup::Apply. The activity log, the crawler status and the ops facts are read once per instance (build a
    # new one to read them again). Each check answers nil (safe) or a refusal reason (Sources::Cleanup::REASONS):
    #
    # - #run_refusal (the whole run): the ops DB is missing or unreadable (:ops_unavailable), the activity log can't be
    #   parsed (:activity_unreadable) — "busy" can't be ruled out then —, an apply of the clean-up page holds the season
    #   lock (:cleanup_running, unless +holds_apply_lock+), the crawler status says a crawl is running (:crawler_busy; a
    #   status not updated for Crawler::RunWatcher::STALE_STATUS_AFTER counts as idle, an unreadable one as busy), or
    #   another crawl entry of the activity log is busy (:crawl_busy). The entry of the crawl job calling the tidy-up
    #   (+own_key+, kind :crawl) is never "busy". With +crawl_slot+ (the caller runs inside the crawl concurrency slot
    #   shared by MeetingCrawlJob, SourceCrawlJob and ManifestExtractJob) only a RUNNING crawl entry refuses: a queued
    #   one cannot start before the caller ends;
    # - #fin_refusal(fin_event_id): the FIN id has a queued/running crawl, extraction or prepare entry (:busy_activity)
    #   or a pending Ops::PipelineRun keyed by it (:prepare_busy);
    # - #entry_refusal(entry): #fin_refusal, a pending extraction run of one of its manifest PDFs (keyed by the PDF
    #   name), and #base_refusal of each of its bases;
    # - #base_refusal(base): the Ops::PipelineSource row of the base holds a lease (:leased), has a queued/running
    #   prepare / extract / build run or a pending commit (:prepare_busy), records operator edits (:edited), or is in
    #   review (:in_review: preparing, needs review, blocked, ready to commit, committing);
    # - #file_refusal(path): Sources::FileGuard (:outside, :missing...), Cleanup.path_refusal, a symlink, a file younger
    #   than Cleanup::MIN_AGE (:too_recent, unless +check_age+ is false), a file named by a busy activity entry or by a
    #   pending extraction run (:busy_activity).
    #
    class Safety # rubocop:disable Metrics/ClassLength
      REVIEW_STAGES = %w[preparing needs_review blocked ready_to_commit committing].freeze

      attr_reader :season_id, :data_root, :guard, :now

      # - own_key: the ActivityLog key of the crawl job calling the tidy-up (its own crawl entry is not "busy");
      # - crawl_slot: true for a caller running inside the crawl concurrency slot (see the class notes);
      # - holds_apply_lock: true for the apply of the clean-up page itself;
      # - crawler_status: the crawler status Hash (default: read from SystemStatus::CrawlerProbe.status_path);
      # - activity_log_path: default SeasonBoard::ActivityLog.default_path.
      def initialize(season_id:, data_root: Sources.data_root, now: Time.current, own_key: nil, crawl_slot: false, # rubocop:disable Metrics/ParameterLists
                     holds_apply_lock: false, crawler_status: :read, activity_log_path: nil)
        @season_id = season_id.to_i
        @data_root = Pathname.new(data_root)
        @guard = FileGuard.new(root: @data_root)
        @now = now
        @own_key = own_key&.to_s
        @crawl_slot = crawl_slot
        @holds_apply_lock = holds_apply_lock
        @crawler_status = crawler_status
        @activity_log_path = Pathname.new(activity_log_path || SeasonBoard::ActivityLog.default_path)
      end

      def run_refusal
        return :ops_unavailable unless ops_facts
        return :activity_unreadable unless busy_entries
        return :cleanup_running if !@holds_apply_lock && ApplyLock.held?(season_id, now:)
        return :crawler_busy if crawler_busy?

        :crawl_busy if other_crawl_busy?
      end

      def fin_refusal(fin_event_id)
        return nil if fin_event_id.blank?
        return :activity_unreadable unless busy_entries
        return :busy_activity if busy_entries.any? { |entry| entry.fin_event_id == fin_event_id.to_s }

        :prepare_busy if pending_subject?(fin_event_id)
      end

      # Refusal of every file of a DiskIndex entry (see the class notes).
      def entry_refusal(entry)
        fin_refusal(entry.fin_event_id) ||
          (:prepare_busy if entry.manifest_pdf_paths.any? { |path| pending_subject?(File.basename(path)) }) ||
          entry.bases.lazy.filter_map { |base| base_refusal(base) }.first
      end

      def base_refusal(base)
        facts = ops_facts
        return :ops_unavailable unless facts
        return :prepare_busy if facts[:pending_subjects].include?(base.to_s) || facts[:pending_bases].include?(base.to_s)

        row = facts[:sources][base.to_s]
        row && source_refusal(row, facts)
      end

      def file_refusal(path, check_age: true)
        real = guard.resolve!(path)
        reason = Cleanup.path_refusal(real, guard:) || (:symlink if File.symlink?(path.to_s))
        return reason if reason
        return :too_recent if check_age && File.mtime(real) > now - MIN_AGE

        :busy_activity if busy_file?(real)
      rescue FileGuard::Refused => e
        e.reason
      end

      # End of the latest crawl attempt recorded for the FIN id (SeasonBoard::ActivityLog keeps only the latest one), or nil.
      def last_crawl_finished_at(fin_event_id)
        return nil if fin_event_id.blank?

        crawl_entries.find { |entry| entry.fin_event_id == fin_event_id.to_s }&.finished_at
      end

      # True when +time+ falls within the run of a crawl recorded in the activity log (any key: a board crawl or a
      # Sources crawl, whose per-FIN entries may be missing), with +tolerance+ at both ends.
      def within_crawl_window?(time, tolerance: 2.seconds)
        crawl_entries.any? do |entry|
          start = entry.started_at || entry.queued_at
          start && time >= start - tolerance && time <= (entry.finished_at || now) + tolerance
        end
      end

      # True when the crawler status says a crawl is running (see the class notes).
      def crawler_busy?
        hash = crawler_status_hash
        return true if hash == :unreadable
        return false if hash.nil?

        status = CrawlerClient::Status.from(hash)
        status.nil? || status.busy?(now:, stale_after: Crawler::RunWatcher::STALE_STATUS_AFTER)
      end

      # The queued/running (not stale) entries of the activity log but the caller's own crawl entry, or nil when the log
      # can't be parsed.
      def busy_entries
        return @busy_entries if defined?(@busy_entries)

        @busy_entries = read_busy_entries&.reject { |entry| entry.kind == :crawl && entry.fin_event_id == @own_key }
      end

      private

      # Refusal from the Ops::PipelineSource row of a base (see #base_refusal).
      def source_refusal(row, facts)
        return :leased if row.lease_owner.present? && row.lease_expires_at.present? && row.lease_expires_at > now
        return :prepare_busy if facts[:pending_source_ids].include?(row.id)
        return :edited if facts[:edited_source_ids].include?(row.id) || row.stage_reason == Ops::PipelineSource::SOURCE_CHANGED_UNDER_EDITS

        :in_review if REVIEW_STAGES.include?(row.stage)
      end

      # True when another crawl entry is busy (inside the crawl slot: running; see the class notes).
      def other_crawl_busy?
        busy_entries.any? { |entry| entry.kind == :crawl && (!@crawl_slot || entry.running?) }
      end

      # True when a busy activity entry names the file, or a pending run has it as subject (an extraction).
      def busy_file?(real)
        named_by_busy_entry?(real) || pending_subject?(real.basename.to_s)
      end

      # True when a pending (not stale) Ops::PipelineRun has +key+ as subject (base, PDF name or FIN id).
      def pending_subject?(key)
        Array(ops_facts&.dig(:pending_subjects)).include?(key.to_s)
      end

      # Every crawl entry of the activity log (the latest attempt of each key), [] when unreadable.
      def crawl_entries
        @crawl_entries ||= begin
          SeasonBoard::ActivityLog.new(path: @activity_log_path).all_entries.select { |entry| entry.kind == :crawl }
        rescue StandardError
          []
        end
      end

      def read_busy_entries
        JSON.parse(@activity_log_path.read) if @activity_log_path.exist? # (a broken file must not read as "nothing busy")
        SeasonBoard::ActivityLog.new(path: @activity_log_path).active(now:)
      rescue JSON::ParserError, SystemCallError => e
        Rails.logger.warn("[Sources::Cleanup::Safety] activity log unreadable: #{e.class}: #{e.message}")
        nil
      end

      def named_by_busy_entry?(real)
        names = [real.to_s, real.basename.to_s]
        extract_key = SeasonBoard::ActivityLog.source_key('extract', real.to_s)
        Array(busy_entries).any? do |entry|
          entry.fin_event_id == extract_key || [entry.url, entry.label].compact.any? do |value|
            names.include?(value.to_s) || names.include?(File.basename(value.to_s))
          end
        end
      end

      def crawler_status_hash
        return @crawler_status unless @crawler_status == :read

        path = SystemStatus::CrawlerProbe.status_path
        path.exist? ? JSON.parse(path.read) : nil
      rescue JSON::ParserError, SystemCallError
        :unreadable
      end

      # { sources: base => Ops::PipelineSource, pending_source_ids:, pending_subjects:, pending_bases:, edited_source_ids: }
      # read once, or nil without the ops DB (or on a failed read).
      def ops_facts
        return @ops_facts if defined?(@ops_facts)

        @ops_facts = Ops.safely(nil) { Ops.available? ? load_ops_facts : nil }
      end

      def load_ops_facts
        sources = Ops::PipelineSource.where(season_id:).index_by(&:base)
        runs = Ops::PipelineRun.pending.to_a.reject { |run| run.stale?(now:) }
        {
          sources:, pending_source_ids: runs.filter_map(&:pipeline_source_id).to_set, pending_subjects: runs.to_set(&:subject_key),
          pending_bases: Ops::CommitReport.pending.pluck(:source_base).compact.to_set,
          edited_source_ids: edited_source_ids(sources.values.map(&:id))
        }
      end

      # Sources whose verdict rows record operator edits or an adopted file (as SeasonBoard::PipelineIndex reads them).
      def edited_source_ids(ids)
        return Set.new if ids.empty?

        Ops::PhaseVerdict.where(pipeline_source_id: ids).select do |verdict|
          counts = verdict.counts.to_h
          verdict.operator_edited_at.present? || counts['_edited'] == true || counts['_adopted'] == true
        end.to_set(&:pipeline_source_id)
      end
    end
  end
end
