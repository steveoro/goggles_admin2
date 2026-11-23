# frozen_string_literal: true

require 'digest'

module Outbox
  #
  # = Outbox::Reconciler
  #
  # Converges the Outbox registry (Ops::SqlScript) with the files on disk: the disk decides pending vs sent,
  # the registry keeps what the disk can't (order, remote id, target, outcome).
  #
  # Scan roots, exactly: <data_root>/results.new/** (but results.new/discarded/), <data_root>/results.sent/**,
  # <data_root>/redo/. Never results.done*, results.backup, results.old. Stat-only for the registered files whose
  # size & mtime didn't change (re-hashed otherwise); unknown files are hashed once.
  #
  # == Rules
  # - unknown file in results.new => pending (kind inferred, applied_locally nil), or held 'not_applied_locally'
  #   (applied_locally false) for the kinds not applied by default (normalize, standard_timings);
  # - unknown file in results.sent => legacy_sent;
  # - unknown file in a legacy folder (redo/, results.new/old-subseeded/) => held 'legacy_folder'
  #   (archived, note ARCHIVE_NOTE, in import mode);
  # - registered file moved by hand (same sha256, old path gone): results.new => results.sent: legacy_sent (+ event);
  #   results.sent => results.new: pending with changed_after_push (+ event); elsewhere: path updated;
  # - pending/held file edited => re-hashed; sent/legacy file edited => changed_after_push;
  # - registered file gone => missing (back to its previous state when it reappears);
  # - a 'pushing' row stale for Ops::SqlScript::STALE_PUSHING_AFTER without a live run => in_doubt.
  #
  # New pending/held rows get Outbox::Sequence.next! (in file-prefix order); legacy rows (legacy_sent, archived)
  # get the lowest free seq numbers, in file-prefix order (they only sort the history).
  #
  # Runs on the Outbox page load (#call_throttled, 30 s), before every push run, from the dashboard "Needs you"
  # refresh, from 'rake outbox:reconcile' and from 'rake ops:rebuild' (Ops::Rebuilders, :outbox).
  # The one-time import is 'rake outbox:import' (Outbox::ImportLegacyJob: import mode, simulate by default).
  #
  # == Usage
  #   report = Outbox::Reconciler.call                         # apply
  #   report = Outbox::Reconciler.call(import: true, simulate: true)
  #   report.counts  # => { 'legacy_sent' => 431, 'archived' => 19, 'held' => 1, ... }
  #   report.lines   # => printable summary
  #
  class Reconciler # rubocop:disable Metrics/ClassLength
    THROTTLE = 30.seconds
    THROTTLE_KEY = 'outbox.reconciled_at'
    IMPORTED_AT_KEY = 'outbox.legacy_imported_at'
    ARCHIVE_NOTE = 'pre-Outbox leftover'

    # A file found under a scan root.
    FileInfo = Data.define(:rel_path, :path, :location, :folder, :size, :mtime) do
      def filename = File.basename(rel_path)
      def legacy? = location == :redo || (location == :new && Outbox::LEGACY_FOLDERS.include?(folder))
      def prefix = Outbox::Sequence.prefix_of(filename).to_i
    end

    # Outcome of a run. counts: action/state => number of files; changes: [action, rel_path] pairs.
    Report = Data.define(:mode, :simulate, :skipped, :counts, :changes, :scanned, :registered) do
      def lines
        head = "Outbox #{mode}#{' (SIMULATE: nothing written)' if simulate}: #{scanned} file(s) scanned, " \
               "#{registered} registered before the run"
        return ["#{head}; skipped (#{skipped})"] if skipped

        body = counts.sort.map { |action, count| format('  %-20<action>s %<count>5d', action:, count:) }
        [head, *(body.presence || ['  nothing to change'])]
      end

      def changed? = counts.except('unchanged').values.sum.positive?
    end

    class << self
      def call(data_root: Outbox.data_root, import: false, simulate: false)
        new(data_root:, import:, simulate:).call
      end

      # Same as #call, at most once every THROTTLE (shared across processes through an Ops::Setting).
      # Returns the Report, or nil when skipped. Never raises.
      def call_throttled(data_root: Outbox.data_root, now: Time.current)
        Ops.safely do
          next unless Ops.available?

          last = last_run_at
          next if last && last > now - THROTTLE

          call(data_root:)
        end
      end

      # Time of the last applied run (or nil).
      def last_run_at
        value = Ops.safely { Ops::Setting.fetch(THROTTLE_KEY) if Ops.available? }
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      # True once the one-time legacy import was applied.
      def imported?
        Ops.safely(false) { Ops.available? && Ops::Setting.fetch(IMPORTED_AT_KEY).present? }
      end
    end

    def initialize(data_root: Outbox.data_root, import: false, simulate: false)
      @data_root = Pathname.new(data_root)
      @import = import
      @simulate = simulate
      @counts = Hash.new(0)
      @changes = []
      @operations = []
    end

    def call
      ops_ready = Ops.available?
      return skipped_report(Ops.state) unless ops_ready || @simulate

      Outbox.guard_test_path!(@data_root) unless @simulate

      files = scan
      rows = ops_ready ? Ops::SqlScript.all.to_a.each { |row| row.data_root = @data_root } : []
      plan(files, rows)
      apply! if ops_ready && !@simulate
      Report.new(mode:, simulate: @simulate, skipped: nil, counts: @counts.to_h, changes: @changes, scanned: files.size,
                 registered: rows.size)
    end

    private

    def mode = @import ? 'import' : 'reconcile'

    def skipped_report(reason)
      Report.new(mode:, simulate: @simulate, skipped: "ops DB #{reason}",
                 counts: {}, changes: [], scanned: 0, registered: 0)
    end

    # == Scan

    # Hash rel_path => FileInfo
    def scan
      infos = scan_dir(Outbox::NEW_DIR, :new) + scan_dir(Outbox::SENT_DIR, :sent) + scan_dir(Outbox::REDO_DIR, :redo)
      infos.index_by(&:rel_path)
    end

    def scan_dir(dir, location)
      root = @data_root.join(dir)
      return [] unless root.directory?

      Dir.glob(root.join('**', '*.sql').to_s).filter_map do |path|
        rel_path = Outbox.relative_path(path, data_root: @data_root)
        segments = rel_path.split('/')
        next if location == :new && segments[1] == Outbox::DISCARDED_DIR
        next unless File.file?(path)

        stat = File.stat(path)
        FileInfo.new(rel_path:, path:, location:, folder: folder_for(location, segments),
                     size: stat.size, mtime: stat.mtime)
      end
    end

    def folder_for(location, segments)
      return Outbox::REDO_DIR if location == :redo

      segments.size > 2 ? segments[1] : Outbox::MISC_FOLDER
    end

    # == Plan (read only: hashes the changed & unknown files)

    def plan(files, rows)
      by_path = rows.index_by(&:rel_path)
      plan_registered(files, by_path)
      unknown = files.values.reject { |info| by_path.key?(info.rel_path) }
      gone = rows.reject { |row| files.key?(row.rel_path) || row.discarded? }
      moved_rows = plan_unknown(unknown, gone)
      (gone - moved_rows).each { |row| plan_gone(row) }
      plan_stale_pushing(rows)
    end

    def plan_registered(files, by_path) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      files.each_value do |info|
        row = by_path[info.rel_path]
        next unless row

        attributes = {}
        attributes.merge!(content_changes(row, info)) if stat_changed?(row, info)
        if row.missing?
          attributes[:state] = row.previous_state.presence || 'pending'
          attributes[:previous_state] = nil
        end
        if @import && row.held? && row.held_reason == 'legacy_folder'
          attributes.merge!(state: 'archived', held_reason: nil, note: ARCHIVE_NOTE, resolved_at: Time.current)
        end
        next count('unchanged') if attributes.empty?

        record(action_for(row, attributes), info.rel_path) { row.update!(attributes) }
      end
    end

    def stat_changed?(row, info)
      row.byte_size != info.size || row.file_mtime.to_i != info.mtime.to_i
    end

    def content_changes(row, info)
      stat = { byte_size: info.size, file_mtime: info.mtime }
      sha = Digest::SHA256.file(info.path).hexdigest
      return stat if sha == row.sha256

      single_transaction = Outbox::Kinds.single_transaction?(File.binread(info.path))
      return stat.merge(sha256: sha, single_transaction:) if row.needs_push?

      stat.merge(sha256: sha, single_transaction:, changed_after_push: true)
    end

    def action_for(row, attributes)
      return 'archived' if attributes[:state] == 'archived'
      return 'reappeared' if row.missing?
      return 'changed_after_push' if attributes[:changed_after_push]
      return 'rehashed' if attributes.key?(:sha256)

      'restat'
    end

    # Plans the unknown files (moves of gone rows first); returns the gone rows matched by a move.
    def plan_unknown(unknown, gone)
      gone_by_sha = gone.group_by(&:sha256)
      moved = []
      unknown.sort_by { |info| [info.prefix, info.rel_path] }.each do |info|
        sha = Digest::SHA256.file(info.path).hexdigest
        row = gone_by_sha[sha]&.find { |candidate| moved.exclude?(candidate) }
        if row
          moved << row
          plan_move(row, info)
        else
          plan_new(info, sha)
        end
      end
      moved
    end

    def plan_move(row, info) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
      attributes = { rel_path: info.rel_path, filename: info.filename, folder: info.folder,
                     byte_size: info.size, file_mtime: info.mtime, previous_state: nil }
      action = 'moved'
      if info.location == :sent && row.in_new_dir?
        attributes[:state] = 'legacy_sent'
        action = 'moved_to_sent'
      elsif info.location == :new && row.in_sent_dir?
        attributes[:state] = 'pending'
        attributes[:changed_after_push] = true
        action = 'moved_back'
      elsif row.missing?
        attributes[:state] = row.previous_state.presence || 'pending'
      end
      record(action, info.rel_path) do
        from = row.rel_path
        row.update!(attributes)
        if %w[moved_to_sent moved_back].include?(action)
          Ops.record_event!(kind: 'outbox.moved_by_hand', level: 'warning', season_id: row.season_id,
                            subject_type: 'sql_script', subject_key: row.id, data: { 'from' => from, 'to' => info.rel_path })
        end
      end
    end

    def plan_new(info, sha)
      attributes = new_attributes(info, sha)
      record(attributes[:state], info.rel_path) do
        attributes[:seq] = legacy_state?(attributes[:state]) ? next_legacy_seq : Outbox::Sequence.next!(data_root: @data_root)
        Ops::SqlScript.create!(attributes)
      end
    end

    def legacy_state?(state) = %w[legacy_sent archived].include?(state)

    def new_attributes(info, sha)
      kind = Outbox::Kinds.infer(info.filename, folder: info.folder)
      base = {
        rel_path: info.rel_path, filename: info.filename, folder: info.folder, season_id: Outbox.season_id_for(info.folder),
        kind:, sha256: sha, byte_size: info.size, file_mtime: info.mtime, applied_locally: nil,
        single_transaction: Outbox::Kinds.single_transaction?(File.binread(info.path)),
        origin: { 'producer' => 'reconciler', 'adopted_at' => Time.current.iso8601 }
      }
      base.merge(state_for_new(info, kind))
    end

    def state_for_new(info, kind)
      return { state: 'legacy_sent' } if info.location == :sent

      if info.legacy?
        return { state: 'archived', note: ARCHIVE_NOTE, resolved_at: Time.current } if @import

        return { state: 'held', held_reason: 'legacy_folder' }
      end
      return { state: 'held', held_reason: 'not_applied_locally', applied_locally: false } unless Outbox::Kinds.applied_locally_by_default?(kind)

      { state: 'pending' }
    end

    # Lowest seq not used by any registered script (legacy rows only sort the history).
    def next_legacy_seq
      @taken_seqs ||= Ops::SqlScript.pluck(:seq).to_set
      @legacy_seq = (@legacy_seq || 0) + 1
      @legacy_seq += 1 while @taken_seqs.include?(@legacy_seq)
      @taken_seqs << @legacy_seq
      @legacy_seq
    end

    def plan_gone(row)
      return count('unchanged') if row.missing?

      record('missing', row.rel_path) { row.mark_missing! }
    end

    def plan_stale_pushing(rows)
      stale = rows.select(&:stale_pushing?)
      return if stale.empty?
      return if !@simulate && Ops::PushRun.live?

      stale.each do |row|
        record('in_doubt', row.rel_path) do
          row.mark_in_doubt!
          Ops.record_event!(kind: 'outbox.in_doubt', level: 'warning', season_id: row.season_id,
                            subject_type: 'sql_script', subject_key: row.id, data: { 'file' => row.filename })
        end
      end
    end

    # == Apply

    def count(action)
      @counts[action] += 1
    end

    def record(action, rel_path, &operation)
      count(action)
      @changes << [action, rel_path]
      @operations << operation
    end

    def apply!
      Ops::ApplicationRecord.transaction do
        @operations.each(&:call)
        Ops::Setting.store!(THROTTLE_KEY, Time.current.iso8601)
      end
      Outbox::Notifier.ping if @counts.except('unchanged').values.sum.positive?
    end
  end
end
