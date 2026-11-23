# frozen_string_literal: true

# = FileCounter
#
# Shared helper returning the last progressive counter used as the leading part ('NNNN-') of the .sql file
# names stored under crawler/data/results.* folders.
#
# Since the SQL Outbox (phase 07) this is a shim over Outbox::Sequence: the counter is GLOBAL (every folder,
# results.new, results.sent and redo, plus the ops registry), no longer per season folder. New producers
# should call Outbox::Writer.write!, which allocates the number itself.
#
module FileCounter
  extend ActiveSupport::Concern

  private

  # Returns the highest counter used so far (the next file should use it + 1).
  #
  # === Params:
  # - <tt>curr_dir</tt> => current working folder (typically "crawler/data/results.new/<SEASON_ID>"): its data
  #   root (the path before 'results.new') is the one scanned, so that specs using a temporary data root stay
  #   isolated;
  # - <tt>sent_dir</tt>, <tt>extension</tt> => unused, kept for compatibility.
  #
  def compute_file_counter(curr_dir, _sent_dir = nil, _extension = '*.sql')
    Outbox::Sequence.current_max(data_root: Outbox.data_root_for(curr_dir))
  end
end
