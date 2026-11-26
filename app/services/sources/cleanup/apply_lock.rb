# frozen_string_literal: true

require 'securerandom'

module Sources
  module Cleanup
    #
    # = Sources::Cleanup::ApplyLock
    #
    # Per-season exclusive lock of the clean-up page apply (0.10.104): a lock file 'tmp/cleanup-apply-<season>.lock'
    # created with File::CREAT | File::EXCL (atomic), holding a random token, removed by its owner when the apply ends
    # (always: #synchronize uses ensure). A lock file older than STALE_AFTER (a killed process) is taken over.
    # While it is held, a second apply of the season is refused and the automatic tidy-ups skip the season
    # (Sources::Cleanup::Safety#run_refusal, reason :cleanup_running).
    #
    class ApplyLock
      STALE_AFTER = 30.minutes

      class_attribute :lock_dir, default: nil

      def self.path_for(season_id)
        Pathname.new(lock_dir || Rails.root.join('tmp')).join("cleanup-apply-#{season_id.to_i}.lock")
      end

      # True when a (not stale) lock file exists for the season.
      def self.held?(season_id, now: Time.current)
        path = path_for(season_id)
        path.exist? && path.mtime > now - STALE_AFTER
      rescue SystemCallError
        false
      end

      def initialize(season_id)
        @path = self.class.path_for(season_id)
        @token = SecureRandom.hex(8)
      end

      # Yields while holding the lock; returns false (without yielding) when another apply holds it.
      def synchronize
        return false unless acquire

        begin
          yield
        ensure
          release
        end
      end

      private

      def acquire(retried: false)
        FileUtils.mkdir_p(@path.dirname)
        File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write("#{@token} #{Process.pid} #{Time.current.iso8601}\n") }
        true
      rescue Errno::EEXIST
        return false if retried || !take_over_stale

        acquire(retried: true)
      end

      def stale?
        @path.mtime <= Time.current - STALE_AFTER
      rescue SystemCallError
        true
      end

      # Removes a stale lock file (a lock file, not a data file); true when the lock can be tried again.
      def take_over_stale
        return false unless stale?

        File.delete(@path)
        true
      rescue Errno::ENOENT
        true
      end

      def release
        File.delete(@path) if @path.exist? && @path.read.start_with?(@token)
      rescue SystemCallError => e
        Rails.logger.warn("[Sources::Cleanup::ApplyLock] lock not released: #{e.class}: #{e.message}")
      end
    end
  end
end
