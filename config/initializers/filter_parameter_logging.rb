# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [:password]
# (Phase 14: the one-time progress token of a guided DB restore, /db_restore/:id?token=..., and the API token kept
#  by a restore run; the SQL statements carrying the latter run with the SQL log silenced, see DbRestore::Preserver)
Rails.application.config.filter_parameters += [/\Atoken\z/, :jwt, :preserved]
# (The redirect to the progress page carries its token: "Redirected to [FILTERED]")
Rails.application.config.filter_redirect << %r{/db_restore/\d+\?.*token=}
