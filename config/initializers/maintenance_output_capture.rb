# frozen_string_literal: true

# Phase 11: installs the $stdout proxy of Maintenance::OutputCapture (once, after boot, so that the autoloaded
# module is available). It is transparent: without an active capture on the current thread every write goes to the
# original $stdout (terminal, rake task output, RSpec's reporter); only Maintenance::OutputCapture.capture blocks
# (the dry run of a maintenance operation) are diverted to their own buffer.
Rails.application.config.after_initialize do
  Maintenance::OutputCapture.install!
end
