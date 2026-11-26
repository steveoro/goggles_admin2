# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::Mover
    #
    # The only file operation of the clean-ups (0.10.104): moves one file of the data root into a folder, keeping its
    # name, NEVER overwriting and never deleting anything.
    #
    # - The source must resolve inside the data root (Sources::FileGuard) and pass Cleanup.path_refusal (no '.sql',
    #   archive folder, Sources::FilePolicy refusal, phase file, LT4 working copy, ...); a symlink is never moved.
    # - When the destination folder already holds a file of that name: identical content (SHA-256) => the source goes
    #   into the duplicates folder of the run backup folder ('<run folder>/duplicates/<origin folder>') instead (when an
    #   origin is given); different content => skipped, reason :name_collision.
    # - The move itself is a hard link to the target (it fails when the target exists: no race can overwrite) followed
    #   by the removal of the source name; on a file system without hard links, a rename after a last existence check.
    # - Every completed move is appended at once to the MOVES.txt of the run backup folder (RunFolder#record!), the
    #   manifests archived to manifests.done and the calendar files moved to calendar.done included.
    #
    # #call returns an Outcome (status :moved, :duplicate or :skipped with a reason); a refusal never raises, a file
    # system error does (the caller decides: Apply stops, the automatic tidy-ups report it).
    #
    class Mover
      Outcome = Data.define(:status, :from, :to, :reason) do
        def moved? = status == :moved
        def duplicate? = status == :duplicate
        def skipped? = status == :skipped
        # True when the file left its folder (moved to its destination, or to the duplicates folder).
        def done? = moved? || duplicate?
      end

      attr_reader :guard, :run_folder

      def self.sha256(path)
        Digest::SHA256.file(path.to_s).hexdigest
      end

      # True when the two files have the same content.
      def self.same_content?(path, other)
        File.size(path) == File.size(other) && sha256(path) == sha256(other)
      end

      # 'manifests.done/<season>' (Pathname under the guard root) for a real manifest path.
      def self.manifests_done_dir(real_pdf_path, guard)
        guard.root.join('manifests.done', Pathname.new(real_pdf_path).dirname.basename)
      end

      # - run_folder: the RunFolder of the run (backup folder, duplicates, MOVES.txt).
      def initialize(guard:, run_folder:)
        @guard = guard
        @run_folder = run_folder
      end

      # nil when +dir+ holds no file named as +path+; else :identical or :different (SHA-256).
      def collision(path, dir)
        target = Pathname.new(dir).join(File.basename(path.to_s))
        return nil unless target.exist? || target.symlink?
        return :different unless target.file?

        self.class.same_content?(path, target) ? :identical : :different
      end

      # Moves +path+ into the run backup folder. Returns an Outcome.
      def to_backup(path)
        source, reason = checked(path)
        return skipped(path, reason) if reason

        place(source, -> { run_folder.path }, :moved)
      end

      # Moves +path+ into +dir+ (see the class notes); +duplicate_origin+: the name of the origin folder of an identical
      # copy in the duplicates folder (nil: an identical copy is skipped too). Returns an Outcome.
      def call(path, dir:, duplicate_origin: nil)
        source, reason = checked(path)
        return skipped(path, reason) if reason

        case collision(source, dir)
        when :different then skipped(path, :name_collision, Pathname.new(dir).join(source.basename))
        when :identical
          return skipped(path, :name_collision, Pathname.new(dir).join(source.basename)) unless duplicate_origin

          place(source, -> { run_folder.path.join(DUPLICATES_FOLDER, duplicate_origin) }, :duplicate)
        else place(source, -> { dir }, :moved)
        end
      end

      # Archives a pending manifest PDF ('manifests/<season>/manifest-<base>.pdf') and its '.txt' into
      # 'manifests.done/<season>', the folder PdfManifests::Extraction.archive uses, with the non-overwriting move of
      # #call for each file (identical copy already there => duplicates folder, different => skipped). Returns the
      # Outcomes (PDF first).
      def archive_manifest(pdf_path)
        source, reason = checked(pdf_path)
        reason ||= :not_cleanable unless source.nil? || guard.relative(source).start_with?('manifests/')
        return [skipped(pdf_path, reason)] if reason

        done_dir = self.class.manifests_done_dir(source, guard)
        [source, Pathname.new(source.to_s.sub(/\.pdf\z/i, '.txt'))].select(&:file?).map do |path|
          call(path, dir: done_dir, duplicate_origin: 'manifests')
        end
      end

      private

      # [real source Pathname, refusal reason or nil] (the path rules first: a link pointing into a read-only folder is
      # refused as such).
      def checked(path)
        source = guard.resolve!(path)
        [source, Cleanup.path_refusal(source, guard:) || (:symlink if File.symlink?(path.to_s))]
      rescue FileGuard::Refused => e
        [nil, e.reason]
      end

      # +dir+: a Proc giving the destination folder (the run folder is reserved only when a move really happens).
      def place(source, dir, status)
        target = guard.resolve_target!(Pathname.new(dir.call).join(source.basename))
        [source, target].each { |path| Outbox.guard_test_path!(path) } # (specs never move the real crawler/data files)
        FileUtils.mkdir_p(target.dirname)
        no_clobber_move(source, target)
        outcome = Outcome.new(status:, from: source.to_s, to: target.to_s, reason: nil)
        run_folder.record!(outcome)
        outcome
      rescue FileGuard::Refused => e
        skipped(source, e.reason)
      end

      def no_clobber_move(source, target)
        if hard_link(source, target)
          File.unlink(source)
        else
          raise Errno::EEXIST, target.to_s if target.exist? || target.symlink?

          FileUtils.mv(source, target)
        end
      end

      # true when linked; false when the file system cannot link (another device, no hard links); raises EEXIST.
      def hard_link(source, target)
        File.link(source, target)
        true
      rescue Errno::EXDEV, Errno::EPERM, Errno::EOPNOTSUPP
        false
      end

      def skipped(path, reason, to = nil)
        Outcome.new(status: :skipped, from: path.to_s, to: to&.to_s, reason:)
      end
    end
  end
end
