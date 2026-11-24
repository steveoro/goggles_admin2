# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::ScriptBlocks
  #
  # The transaction blocks of a plan's script lines. A script holding more than one START TRANSACTION ... COMMIT block
  # (e.g. 'season.badge_fix': one block per badge) is NOT atomic on MariaDB, even inside LocalDb::SqlRunner's outer
  # transaction: each nested START TRANSACTION commits what ran before it. Maintenance::Executor therefore runs such a
  # script block by block and registers exactly the blocks that ran (see Executor#apply_blocks!).
  #
  # == Usage
  #   Maintenance::ScriptBlocks.split(plan.sql_lines)   # => [[lines of block 1], [lines of block 2], ...]
  # The blocks partition the lines (their concatenation is the original Array): a block ends with the element holding
  # its COMMIT; the lines after the last COMMIT (comments, blanks) stay with the last block. A script with at most one
  # COMMIT is one block.
  #
  module ScriptBlocks
    COMMIT_REGEXP = /\A\s*COMMIT\s*;/i

    module_function

    def split(lines)
      blocks = [[]]
      Array(lines).each do |element|
        blocks.last << element
        blocks << [] if commit?(element)
      end
      tail = blocks.pop
      return [tail] if blocks.empty?

      blocks.last.concat(tail)
      blocks
    end

    # True when the element (possibly several lines) holds a COMMIT statement.
    def commit?(element)
      element.to_s.split(/\r?\n/).any? { |line| COMMIT_REGEXP.match?(line) }
    end
  end
end
