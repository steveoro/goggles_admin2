# frozen_string_literal: true

require 'digest'

# = DataFixHelper
#
# View helpers of the Data-Fix review pages (phase 12).
module DataFixHelper
  # DOM id of the Turbo frame wrapping a Step 2/3 card, based on the row key (e.g. "team-card-k-0a1b2c3d4e"): the
  # positional 'team-card-<N>' ids stay on the card itself, but N is the position in the filtered page and changes
  # when a saved card leaves the filter, so the in-place replacement targets the key-based frame.
  def data_fix_card_frame_id(kind, key)
    "#{kind}-card-k-#{Digest::SHA1.hexdigest(key.to_s)[0, 10]}"
  end

  # Issue codes => the space-separated `data-issue` marker value (nil when the card needs nothing).
  def data_fix_issue_marker(codes)
    Array(codes).compact_blank.uniq.join(' ').presence
  end

  # Tooltip text of the "needs you" badge of a card.
  def data_fix_issue_title(codes)
    Array(codes).compact_blank.uniq.map { |code| t("data_fix.verdicts.issues.#{code}", default: code.to_s.humanize) }.join(' • ')
  end
end
