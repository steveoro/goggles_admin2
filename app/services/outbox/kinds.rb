# frozen_string_literal: true

module Outbox
  #
  # = Outbox::Kinds
  #
  # The kind of an SQL script (who produced it), and the content checks done when a script is registered.
  #
  # Scripts written through Outbox::Writer carry their kind; files found on disk (legacy, dropped by hand)
  # get the kind inferred from their name (#infer), first matching rule wins.
  #
  module Kinds
    ALL = %w[commit calendar_link backfill team_manager cancel_flag merge fix purge recompute normalize
             standard_timings categories check goggle_cup manual].freeze

    # Name rules (on the basename), in order: the first match wins.
    NAME_RULES = [
      ['cancel_flag', /-(?:meeting|calendar)_cancel-/],
      ['calendar_link', /-calendar_link-/],
      ['backfill', /-season_board_backfill-/],
      ['team_manager', /-team_manager-/],
      ['standard_timings', /standard_timings/],
      ['normalize', /normalize_/],
      ['categories', /import_categories-/],
      ['check', /fix_dup_results-/],
      ['merge', /merge_|season_fix|dedup_|relay(?:_only)?_badges-/],
      ['fix', /fix_|datafix/],
      ['purge', /purge_/],
      ['recompute', /recompute_/],
      # Data-Fix commit batches: '<NNNN>-<base>-lt4.sql' (older ones '-l4.sql' or a dated '<NNNN>-YYYY-MM-DD-<name>.sql')
      ['commit', /-l(?:t)?4\.sql\z|\A\d+-\d{4}-\d{2}-\d{2}-/]
    ].freeze

    # Kinds that are not applied on the local DB when written (held until "Apply locally").
    NOT_APPLIED_LOCALLY = %w[normalize standard_timings].freeze

    # A second COMMIT, or DDL, makes a script not a single transaction (the outer wrapper can't roll it back).
    COMMIT_REGEXP = /^\s*COMMIT\s*;/i
    DDL_REGEXP = /^\s*(?:CREATE|ALTER|DROP|TRUNCATE)\s/i

    module_function

    # Kind inferred from the file name (and its folder: 'goggle_cups' scripts are 'goggle_cup').
    def infer(filename, folder: nil)
      return 'goggle_cup' if folder.to_s == 'goggle_cups'

      name = File.basename(filename.to_s)
      NAME_RULES.each { |kind, regexp| return kind if regexp.match?(name) }
      'manual'
    end

    # True when the name looks like a Data-Fix commit batch (see #infer).
    def commit_name?(filename)
      infer(filename) == 'commit'
    end

    def valid?(kind)
      ALL.include?(kind.to_s)
    end

    # True when a script of this kind is applied on the local DB when written (default for unknown kinds).
    def applied_locally_by_default?(kind)
      NOT_APPLIED_LOCALLY.exclude?(kind.to_s)
    end

    # False when the SQL text holds more than one COMMIT or any DDL statement.
    def single_transaction?(sql)
      text = sql.to_s
      text.scan(COMMIT_REGEXP).size <= 1 && !DDL_REGEXP.match?(text)
    end
  end
end
