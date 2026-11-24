# frozen_string_literal: true

module Sources
  #
  # = Sources::FilePolicy
  #
  # What the file manager may do with a file of the data root (a path relative to it, see Sources::FileGuard):
  #
  # - the unreferenced folders (READ_ONLY_FOLDERS, and the dated or '.backup' / '.old' copies) are read-only;
  # - the files right under the data root (the watcher, board and crawler state files) are read-only;
  # - SQL scripts belong to the SQL Outbox (it follows them by name and checksum): read-only here;
  # - only the JSON, CSV and TXT files up to MAX_EDIT_BYTES can be edited; any other file can be renamed or deleted.
  #
  # #refusal returns the i18n key ('sources.files.refused.<key>') of the reason, or nil when the action is allowed.
  #
  module FilePolicy
    ACTIONS = %i[edit rename delete].freeze
    READ_ONLY_FOLDERS = %w[pdfs.done pdfs.backup results.backup results.old redo].freeze
    # Dated or backup copies of a folder (e.g. 'results.done.2024').
    READ_ONLY_PATTERN = /\.(backup|old|\d{4})\z/
    EDITABLE_EXTENSIONS = %w[.json .csv .txt].freeze
    OUTBOX_EXTENSIONS = %w[.sql].freeze
    MAX_EDIT_BYTES = 10 * 1024 * 1024

    module_function

    # True when the top-level folder of +relative_path+ is read-only.
    def read_only_folder?(relative_path)
      top = relative_path.to_s.split('/').first.to_s
      READ_ONLY_FOLDERS.include?(top) || READ_ONLY_PATTERN.match?(top)
    end

    # Reason key refusing +action+ on the file (nil when allowed).
    # - size: the file size in bytes (for :edit).
    def refusal(action, relative_path, size: 0)
      relative = relative_path.to_s
      return :read_only_folder if read_only_folder?(relative)
      return :state_file unless relative.include?('/')

      ext = File.extname(relative).downcase
      return :outbox_script if OUTBOX_EXTENSIONS.include?(ext)
      return unless action.to_sym == :edit
      return :not_editable unless EDITABLE_EXTENSIONS.include?(ext)

      :too_large if size.to_i > MAX_EDIT_BYTES
    end

    def allowed?(action, relative_path, size: 0) = refusal(action, relative_path, size:).nil?

    # Reason key refusing a rename to +target_relative+ (nil when allowed): never into a read-only folder, onto the
    # data root itself or into an Outbox file.
    def target_refusal(target_relative)
      relative = target_relative.to_s
      return :read_only_folder if read_only_folder?(relative)
      return :state_file unless relative.include?('/')

      :outbox_script if OUTBOX_EXTENSIONS.include?(File.extname(relative).downcase)
    end
  end
end
