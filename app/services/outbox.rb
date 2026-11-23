# frozen_string_literal: true

#
# = Outbox
#
# The SQL Outbox: one ordered registry (ops DB, Ops::SqlScript) of every SQL script that changes the local DB,
# whatever its producer (Data-Fix commit, Season board, team managers, rake tasks, a file dropped by hand), and
# the page pushing them to the API in local-apply order (OutboxController, Outbox::PushJob). See docs/outbox.md.
#
# Files keep their conventions ('NNNN-<name>.sql' under <data_root>/results.new/<folder>/, moved to
# results.sent/<folder>/ once pushed): the disk decides pending vs sent, the registry holds what the disk can't
# (global order, remote import queue id, target, outcome).
#
# == Main entry points
# - Outbox::Writer.write!(kind:, name:, sql:, folder:, ...)   # every producer
# - Outbox::Sequence.next! / .current_max(data_root:)         # global order
# - Outbox::Reconciler.call(data_root:)                       # disk => registry
# - Outbox::Summary.call                                      # counters (dashboard, inbox)
#
module Outbox
  # Base error of the Outbox services.
  class Error < StandardError; end

  # Folders scanned under the data root (never results.done*, results.backup, results.old):
  NEW_DIR = 'results.new'
  SENT_DIR = 'results.sent'
  REDO_DIR = 'redo'
  # Subfolder of results.new receiving the discarded scripts (never scanned).
  DISCARDED_DIR = 'discarded'
  # Cross-season scripts (maintenance, rake tasks).
  MISC_FOLDER = 'misc'
  # Folders of results.new holding pre-Outbox leftovers (imported as archived, see Outbox::Reconciler).
  LEGACY_FOLDERS = %w[old-subseeded].freeze

  module_function

  # The crawler data folder (Pathname).
  def data_root
    Rails.root.join('crawler/data')
  end

  # Data root of a path lying somewhere under '<data_root>/results.new' or '<data_root>/results.sent'
  # (e.g. a Data-Fix source path), so that specs using a temporary data root stay isolated. Falls back
  # to +default+ when the path has no such segment.
  def data_root_for(path, default: data_root)
    text = Pathname.new(path.to_s).expand_path(Rails.root).to_s + File::SEPARATOR
    [NEW_DIR, SENT_DIR].each do |dir|
      index = text.index("/#{dir}/")
      return Pathname.new(text[0...index]) if index
    end
    Pathname.new(default)
  end

  # Path of +path+ relative to +data_root+ (String), e.g. 'results.new/262/0012-x.sql'.
  def relative_path(path, data_root: self.data_root)
    Pathname.new(File.expand_path(path.to_s, Rails.root)).relative_path_from(Pathname.new(data_root).expand_path).to_s
  end

  # Season id for a folder name ('262' => 262, 'misc' => nil).
  def season_id_for(folder)
    Integer(folder.to_s, 10, exception: false)
  end

  # Spec guard (test environment only): raises when +path+ lies under the real crawler data folder, so that no spec
  # ever writes, moves or registers the real scripts (specs pass a temporary data_root, or stub Outbox.data_root).
  def guard_test_path!(path)
    return unless Rails.env.test?

    real = Rails.root.join('crawler/data').expand_path.to_s
    target = Pathname.new(path.to_s).expand_path.to_s
    return unless target == real || target.start_with?("#{real}/")

    raise Outbox::Error, "spec touching the real crawler data folder (#{target}): use a temporary data_root"
  end
end
