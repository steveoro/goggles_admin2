# frozen_string_literal: true

# = PushController
#
# Kept only for the old bookmarks: the Push page was replaced by the SQL Outbox (phase 07, see
# OutboxController), which pushes every pending script in local-apply order through a clicked background job.
#
class PushController < ApplicationController
  # [GET] /push/index => /outbox (the old 'curr_dir' / 'parent_folder' params are dropped)
  def index
    redirect_to(outbox_path, status: :moved_permanently)
  end
end
