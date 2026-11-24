# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::DumpCatalog
  #
  # The production dumps a restore can use (wizard step 2): the '*.sql.bz2' files whose name starts with
  # 'production' in the configured folders, newest first. Default folders: goggles_main/db/dump (where the operator
  # copies the server dumps by hand, as 'production-NNNN-label.sql.bz2') and this app's db/dump; editable in the
  # Ops::Setting 'db_restore.dump_dirs' (one absolute path per entry).
  #
  # Fetching a dump from production stays a manual step. The safety snapshot goes to the first existing folder, as
  # 'development-<NNNN>-pre-restore.sql.bz2' (NNNN: the next number over every 'production-' / 'development-' dump).
  #
  class DumpCatalog
    SETTING_KEY = 'db_restore.dump_dirs'
    PRODUCTION_GLOB = 'production*.sql.bz2'
    NUMBERED = /\A(?:production|development)-(\d{4})[-_]/

    Entry = Data.define(:path, :dir, :basename, :bytes, :mtime, :number) do
      # The dump name db:rebuild expects ('from=<name>').
      def rebuild_name = basename.delete_suffix('.sql.bz2')
    end

    # Default folders (absolute Strings).
    def self.default_dirs
      [Rails.root.join('../goggles_main/db/dump').expand_path.to_s, Rails.root.join('db/dump').to_s]
    end

    # Stores the folders typed by the operator (one per line; blank => defaults); returns the stored list.
    def self.store_dirs!(text)
      dirs = text.to_s.split(/[\r\n]+/).map(&:strip).compact_blank.map { |dir| File.expand_path(dir) }.uniq
      Ops::Setting.store!(SETTING_KEY, dirs.presence)
      dirs.presence || default_dirs
    end

    def initialize(dirs: nil)
      @dirs = dirs
    end

    # Configured folders (absolute Strings): explicit, stored setting or defaults.
    def dirs
      @dirs ||= (stored_dirs.presence || self.class.default_dirs).map { |dir| File.expand_path(dir.to_s) }.uniq
    end

    def existing_dirs
      dirs.select { |dir| File.directory?(dir) }
    end

    # Production dumps (Array of Entry), newest first.
    def entries
      @entries ||= existing_dirs.flat_map { |dir| Dir.glob(File.join(dir, PRODUCTION_GLOB)) }
                                .select { |path| File.file?(path) }
                                .map { |path| entry_for(path) }
                                .sort_by { |entry| [-entry.mtime.to_f, entry.basename] }
    end

    # The Entry for +path+ when it is one of #entries (nil otherwise: any other path is refused).
    def find(path)
      return if path.blank?

      expanded = File.expand_path(path.to_s)
      entries.find { |entry| entry.path == expanded }
    end

    # Folder of the safety snapshot (first existing configured folder), or nil.
    def snapshot_dir
      existing_dirs.first
    end

    # Next dump number (Integer) over the numbered dumps of every folder.
    def next_number
      numbers = existing_dirs.flat_map { |dir| Dir.glob(File.join(dir, '*.sql.bz2')) }
                             .filter_map { |path| File.basename(path)[NUMBERED, 1]&.to_i }
      (numbers.max || 0) + 1
    end

    # Path of the next safety snapshot (String), or nil without a folder.
    def next_snapshot_path
      dir = snapshot_dir
      dir && File.join(dir, format('development-%04d-pre-restore.sql.bz2', next_number))
    end

    private

    def stored_dirs
      Array(Ops.safely { Ops::Setting.fetch(SETTING_KEY) if Ops.available? }).compact_blank
    end

    def entry_for(path)
      expanded = File.expand_path(path)
      stat = File.stat(expanded)
      basename = File.basename(expanded)
      Entry.new(path: expanded, dir: File.dirname(expanded), basename:, bytes: stat.size, mtime: stat.mtime,
                number: basename[NUMBERED, 1]&.to_i)
    end
  end
end
