# frozen_string_literal: true

# = FileCounter
#
# Shared helper for computing the next progressive counter used as a leading
# filename part for .sql files stored under crawler/data/results.* folders.
#
module FileCounter
  extend ActiveSupport::Concern

  private

  # Returns a valid progressive counter that can be used as a leading file name part to
  # respect their creation order.
  #
  # Takes in consideration both the 'results.new' & the 'results.sent' sub-folders so that
  # the next computed file counter is in continuous progression relative to the whole
  # push process. (That is, the counter should reset only after all the files are processed
  # and moved to the 'results.done' folder.)
  #
  # Assumes files have to be processed in order and moved sequentially:
  # 1) 'results.new'  |=> 'results.sent' (staging phase)
  # 2) 'results.sent' |=> 'results.done' (production phase)
  #
  # === Params:
  # - <tt>curr_dir</tt> => current working folder (typically "crawler/data/results.new/<SEASON_ID>")
  # - <tt>sent_dir</tt> => folder storing the files already processed or sent (typically "crawler/data/results.sent/<SEASON_ID>")
  # - <tt>extension</tt> => file extension of the processed files including wildchar (defaults to '*.sql')
  #
  def compute_file_counter(curr_dir, sent_dir, extension = '*.sql')
    # Prepare a sequential counter prefix for the uploadable batch file:
    curr_count = Rails.root.glob("#{curr_dir}/**/#{extension}").count
    sent_count = Rails.root.glob("#{sent_dir}/**/#{extension}").count
    last_counter = if curr_count.positive?
                     File.basename(Rails.root.glob("#{curr_dir}/**/#{extension}").max).split('-').first.to_i
                   elsif sent_count.positive?
                     File.basename(Rails.root.glob("#{sent_dir}/**/#{extension}").max).split('-').first.to_i
                   else
                     0
                   end
    # In case the saved files didn't contain a leading progressive counter in their name, use the file count:
    last_counter = curr_count + sent_count if last_counter.zero?
    last_counter
  end
end
