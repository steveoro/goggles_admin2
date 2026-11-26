# frozen_string_literal: true

module Sources
  #
  # = Sources::Cleanup
  #
  # Tidy-up of the redundant crawl outputs of a season (0.10.104). Nothing is ever deleted: every file is MOVED
  # (Sources::Cleanup::Mover, hard link + unlink: never an overwrite):
  #
  # - result files of 'results.new/<season>' => 'results.backup/<season>/cleanup-<UTC timestamp>[-N]/', the run backup
  #   folder (Sources::Cleanup::RunFolder: one per run, reserved atomically at the first move);
  # - manifest PDFs (+ their '.txt') => 'manifests.done/<season>' (the folder PdfManifests::Extraction.archive uses);
  # - calendar CSVs of 'calendar.new/<season>' => 'calendar.done/<season>';
  # - a file whose name already exists at its destination with the same content (SHA-256) goes to
  #   '<run backup folder>/duplicates/<folder>/' instead; with a different content it stays where it is (reported);
  # - every completed move is appended at once to the MOVES.txt of the run backup folder, whatever the flow.
  #
  # Who moves what:
  # - automatically, after a crawl, only the files that crawl run wrote: SeasonBoard::CrawlOutput (MeetingCrawlJob) and
  #   Sources::CrawlTidy (SourceCrawlJob: the same CrawlOutput rule per FIN id, plus Sources::CalendarTidy);
  # - by the operator: the clean-up page (Sources::Cleanup::Plan = dry run, Sources::Cleanup::Apply under the
  #   per-season Sources::Cleanup::ApplyLock).
  # The safety checks shared by all of them are in Sources::Cleanup::Safety; #path_refusal holds the ones on the path
  # alone.
  #
  module Cleanup
    # A file younger than this is never touched by a rule that is not "the fresh output of the crawl just ended".
    MIN_AGE = 10.minutes
    # The only folders a clean-up takes files from (each with a <season> subfolder).
    SOURCE_FOLDERS = %w[results.new manifests calendar.new].freeze
    # Archive / backup folders: never a source of a move.
    ARCHIVE_FOLDERS = %w[results.done results.sent results.backup manifests.done calendar.done].freeze
    # The backup folder root (a subfolder per season, then one per run).
    BACKUP_FOLDER = 'results.backup'
    # Subfolder of a run backup folder holding the identical copies of files already at their destination.
    DUPLICATES_FOLDER = 'duplicates'
    # Name of the run backup folder: 'cleanup-<UTC YYYYMMDD-HHMMSS>[-N]' (Sources::Cleanup::RunFolder).
    BACKUP_PREFIX = 'cleanup-'
    # Stand-in for the run timestamp in the dry-run destinations (the folder is named when the moves start).
    TIMESTAMP_PLACEHOLDER = '<timestamp>'
    # List of the moves of a run, appended move by move into its backup folder (to undo them by hand).
    MOVES_FILE = 'MOVES.txt'
    # Names never moved, whatever the rule (reason => regexp), checked on the base name.
    PROTECTED_NAMES = {
      phase_file: SeasonBoard::DiskIndex::PHASE_REGEXP,
      lt4_working_copy: /-lt4\.json\z/,
      backup_copy: SeasonBoard::DiskIndex::SKIPPED_JSON_REGEXP,
      commit_log: /\.log\z/
    }.freeze

    # Every refusal reason (i18n 'sources.cleanup.reasons.<reason>').
    REASONS = %i[
      ops_unavailable activity_unreadable crawler_busy crawl_busy
      outside missing blank not_a_file sql_file archive_folder not_cleanable file_policy symlink
      phase_file lt4_working_copy backup_copy commit_log phase_files
      in_review edited leased prepare_busy busy_activity unlinked_meeting too_recent name_collision
      digest_mismatch nothing_to_move unreadable_json pdf_derived modified_after_crawl cleanup_running apply_running exists
    ].freeze

    module_function

    # The dry-run form of the run backup folder, relative to the data root ('results.backup/262/cleanup-<timestamp>').
    def backup_placeholder(season_id)
      "#{BACKUP_FOLDER}/#{season_id}/#{BACKUP_PREFIX}#{TIMESTAMP_PLACEHOLDER}"
    end

    # Refusal reason (Symbol) for moving the file at +real+ (a real path already resolved by +guard+, see
    # Sources::FileGuard#resolve!) on its path alone, else nil: a '.sql' script (the Outbox owns it), an archive or
    # backup folder, a folder the clean-ups never take from, a Sources::FilePolicy refusal, a protected name
    # (phase file, LT4 working copy, '.orig'/'.committed' copy, commit log).
    def path_refusal(real, guard:)
      relative = guard.relative(real)
      top = relative.split('/').first.to_s
      return :sql_file if File.extname(relative).casecmp?('.sql')
      return :archive_folder if ARCHIVE_FOLDERS.include?(top)
      return :file_policy if Sources::FilePolicy.refusal(:rename, relative)
      return :not_cleanable unless SOURCE_FOLDERS.include?(top) && relative.count('/') == 2

      PROTECTED_NAMES.find { |_reason, regexp| regexp.match?(File.basename(relative)) }&.first
    end
  end
end
