# frozen_string_literal: true

module Outbox
  #
  # = Outbox::Sequence
  #
  # The global local-apply order of the SQL scripts (one sequence for every folder and producer).
  #
  # #next! allocates the next number in a single ops DB transaction (SQLite 'BEGIN IMMEDIATE', the Rails 8
  # default, acts as the cross-process mutex; a Mutex serialises the threads of a process):
  #
  #   max(Ops::Setting 'outbox.last_seq', registry max seq, highest integer prefix on disk) + 1
  #
  # and stores it as the new 'outbox.last_seq'. The disk part reads the file names (no content) under
  # <data_root>/results.new/**, <data_root>/results.sent/** and <data_root>/redo/, never results.done*.
  # When the ops DB is not available both methods fall back to the disk-only max.
  #
  # == Usage
  #   Outbox::Sequence.next!(data_root: Outbox.data_root)      # => 490
  #   Outbox::Sequence.current_max(data_root: Outbox.data_root) # => 490 (read only)
  #   format('%04d', seq)                                       # file prefix
  #
  class Sequence
    SETTING_KEY = 'outbox.last_seq'
    PREFIX_REGEXP = /\A(\d+)-/
    # Glob patterns (relative to the data root) of the files counted by #disk_max:
    DISK_GLOBS = ["#{Outbox::NEW_DIR}/**/*.sql", "#{Outbox::SENT_DIR}/**/*.sql", "#{Outbox::REDO_DIR}/**/*.sql"].freeze
    MUTEX = Mutex.new

    class << self
      # Allocates and returns the next sequence number (Integer).
      def next!(data_root: Outbox.data_root)
        disk = disk_max(data_root)
        return disk + 1 unless Ops.available?

        MUTEX.synchronize do
          Ops::ApplicationRecord.transaction do
            value = [stored_max, disk].max + 1
            Ops::Setting.store!(SETTING_KEY, value)
            value
          end
        end
      rescue StandardError => e
        Rails.logger.warn("[Outbox::Sequence] ops DB allocation failed (#{e.class}: #{e.message}): using the disk max")
        disk_max(data_root) + 1
      end

      # Highest number allocated or found so far (read only).
      def current_max(data_root: Outbox.data_root)
        disk = disk_max(data_root)
        ops = Ops.safely(0) { Ops.available? ? stored_max : 0 }
        [disk, ops.to_i].max
      end

      # Highest integer prefix of the '.sql' files under the scanned folders of +data_root+ (0 when none).
      def disk_max(data_root)
        root = Pathname.new(data_root)
        DISK_GLOBS.flat_map { |pattern| Dir.glob(root.join(pattern).to_s) }
                  .filter_map { |path| prefix_of(path) }
                  .max.to_i
      end

      # Integer prefix of a file name ('0490-x.sql' => 490), or nil.
      def prefix_of(path)
        match = PREFIX_REGEXP.match(File.basename(path.to_s))
        match && match[1].to_i
      end

      private

      def stored_max
        [Ops::Setting.fetch(SETTING_KEY, 0).to_i, Ops::SqlScript.maximum(:seq).to_i].max
      end
    end
  end
end
