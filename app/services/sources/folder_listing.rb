# frozen_string_literal: true

module Sources
  #
  # = Sources::FolderListing
  #
  # One folder of the data root for the Files tab: its subfolders (with their entry count) and its files, the
  # hidden files left out, folders first. Every top-level folder of 'crawler/data' is reachable (also 'misc',
  # 'goggle_cups', 'normalize' and the unreferenced ones, which Sources::FilePolicy keeps read-only).
  # A symbolic link resolving outside the data root (or nowhere) is listed as such, never followed: no size, date or
  # entry count of what it points to, no link and no action.
  #
  class FolderListing
    # Listed entries are capped (a 'results.done' season folder may hold thousands of files).
    MAX_ENTRIES = 1000

    Entry = Data.define(:name, :relative_path, :directory, :size, :mtime, :count, :outside_link) do
      def initialize(outside_link: false, **) = super

      def directory? = directory
      def outside_link? = outside_link
    end

    attr_reader :guard, :relative_dir

    # - dir: folder relative to the data root ('' or nil: the data root itself); a path outside it raises
    #   Sources::FileGuard::Refused.
    def initialize(guard:, dir: nil)
      @guard = guard
      @relative_dir = dir.to_s.delete_prefix('/').delete_suffix('/')
      @real_dir = @relative_dir.empty? ? guard.root : guard.resolve!(@relative_dir, type: :directory)
      @relative_dir = @relative_dir.empty? ? '' : guard.relative(@real_dir)
    end

    def root? = @relative_dir.empty?

    def read_only? = !root? && FilePolicy.read_only_folder?(@relative_dir)

    # Folders first, then files, by name (at most MAX_ENTRIES).
    def entries
      @entries ||= children.first(MAX_ENTRIES).map { |child| entry_for(child) }
    end

    def truncated? = children.size > MAX_ENTRIES

    # [label, relative dir] pairs from the data root down to this folder.
    def crumbs
      parts = @relative_dir.split('/')
      [['crawler/data', '']] + parts.each_index.map { |index| [parts[index], parts[0..index].join('/')] }
    end

    # Relative path of the parent folder (nil at the root).
    def parent_dir
      return if root?

      parent = File.dirname(@relative_dir)
      parent == '.' ? '' : parent
    end

    private

    def children
      @children ||= begin
        list = @real_dir.directory? ? @real_dir.children.reject { |child| child.basename.to_s.start_with?('.') } : []
        list.sort_by { |child| [!outside_link?(child) && child.directory? ? 0 : 1, child.basename.to_s] }
      end
    end

    # True for a symbolic link that does not resolve inside the data root.
    def outside_link?(child)
      return false unless child.symlink?

      !guard.inside?(child.realpath)
    rescue SystemCallError
      true
    end

    def entry_for(child)
      relative = root? ? child.basename.to_s : "#{@relative_dir}/#{child.basename}"
      if outside_link?(child)
        Entry.new(name: child.basename.to_s, relative_path: relative, directory: false, size: nil, mtime: nil, count: nil, outside_link: true)
      elsif child.directory?
        Entry.new(name: child.basename.to_s, relative_path: relative, directory: true, size: nil, mtime: child.mtime,
                  count: child.children.size)
      else
        Entry.new(name: child.basename.to_s, relative_path: relative, directory: false, size: child.size, mtime: child.mtime, count: nil)
      end
    rescue SystemCallError
      Entry.new(name: child.basename.to_s, relative_path: relative, directory: false, size: 0, mtime: nil, count: nil)
    end
  end
end
