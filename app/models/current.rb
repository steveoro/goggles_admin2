# frozen_string_literal: true

#
# = Current
#
# Per-request (or per-job) attributes, reset automatically by the Rails executor:
# - user_id: ID of the signed-in user (nil in jobs and for anonymous requests);
# - source: what is running: 'controller_path#action' for a request (set by ApplicationController),
#   the job class name for a job (set by ApplicationJob).
#
# Read by the remote-write log (APIProxy => Ops::RemoteWrite) to tell where a call came from.
#
class Current < ActiveSupport::CurrentAttributes
  attribute :user_id, :source
end
