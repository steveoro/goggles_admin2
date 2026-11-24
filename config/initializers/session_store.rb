# frozen_string_literal: true

# Be sure to restart your server when you modify this file.
# [Steve A.] NOTE: cookie names prefixed with "__Secure-" or "__Host-" can only be used under HTTPS.
# Also, "__Host-"-type cookies cannot contain a :domain attribute (which is automatically set using the prefix).
Rails.application.config.session_store(
  :active_record_store,
  expire_after: 6.hours,
  same_site: 'Lax',
  # This shouldn't be necessary atm:
  # secure: !(Rails.env.development? || Rails.env.test?),
  key: Rails.env.local? ? '_goggles_admin2_session' : '__Host-goggles_admin2_session'
)

# Phase 14: the session rows live in the local ops DB (table 'sessions'), so the operator stays signed in while a
# guided restore drops and reloads the MySQL primary; MySQL stays the fallback while the ops DB isn't ready
# (see Ops::SessionStoreSetup). Re-installed after each code reload (the Router is autoloaded).
Rails.application.config.to_prepare { Ops::SessionStoreSetup.install! }
