# frozen_string_literal: true

# Be sure to restart your server when you modify this file.
# [Steve A.] NOTE: cookie names prefixed with "__Secure-" or "__Host-" can only be used under HTTPS.
# Also, "__Host-"-type cookies cannot contain a :domain attribute (which is automatically set using the prefix).
Rails.application.config.session_store(
  :cookie_store, # (Default store)
  expire_after: 6.hours,
  same_site: 'Lax',
  # This shouldn't be necessary atm:
  # secure: !(Rails.env.development? || Rails.env.test?),
  key: Rails.env.development? || Rails.env.test? ? '_goggles_admin2_session' : '__Host-goggles_admin2_session'
)
