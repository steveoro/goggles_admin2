# frozen_string_literal: true

require 'fileutils'

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::RunFolder
    #
    # The backup folder of one clean-up run (0.10.104), 'results.backup/<season>/cleanup-<UTC YYYYMMDD-HHMMSS>[-N]',
    # shared by every flow (the board crawl tidy-up, the Sources crawl tidy-up, the calendar tidy-up, the clean-up page):
    #
    # - it is reserved lazily, at the first completed move of the run (#path), with an atomic Dir.mkdir: when two runs
    #   start in the same second, the second one gets the next free '-N' suffix (never a shared folder);
    # - #record! appends one line per completed move to its MOVES.txt (append mode, under an exclusive lock, never
    #   truncated): UTC time, action, source -> destination (relative to the data root). Every move of the run is
    #   listed there, also the manifests archived to manifests.done and the calendar files moved to calendar.done,
    #   so the folder is the undo record of the run.
    #
    class RunFolder
      attr_reader :root, :season_id

      # - root: the (real) data root; now: the run start (names the folder).
      def initialize(root:, season_id:, now: Time.current)
        @root = Pathname.new(root)
        @season_id = season_id.to_s
        @stamp = now.utc.strftime('%Y%m%d-%H%M%S')
        @path = nil
        @moves = 0
      end

      # Number of moves recorded by this run.
      attr_reader :moves

      # True once the folder exists for this run.
      def reserved? = !@path.nil?

      # The reserved folder (Pathname); reserves it on the first call (see the class notes).
      def path
        @path ||= reserve!
      end

      # The folder relative to the data root ('results.backup/262/cleanup-...'), or nil when never reserved.
      def relative
        reserved? ? @path.relative_path_from(@root).to_s : nil
      end

      def journal_path = path.join(MOVES_FILE)

      # Appends the line of a completed move (+outcome+: a Mover::Outcome) to MOVES.txt.
      def record!(outcome)
        line = [Time.now.utc.iso8601, outcome.status, "#{rel(outcome.from)} -> #{rel(outcome.to)}"].join("\t")
        File.open(journal_path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{line}\n")
        end
        @moves += 1
      end

      private

      def reserve!
        base = @root.join(BACKUP_FOLDER, @season_id, "#{BACKUP_PREFIX}#{@stamp}")
        Outbox.guard_test_path!(base) # (specs never write into the real crawler/data)
        FileUtils.mkdir_p(base.dirname)
        candidate = base
        suffix = 1
        begin
          Dir.mkdir(candidate)
        rescue Errno::EEXIST
          suffix += 1
          candidate = Pathname.new("#{base}-#{suffix}")
          retry
        end
        candidate
      end

      def rel(path)
        Pathname.new(path.to_s).relative_path_from(@root).to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
