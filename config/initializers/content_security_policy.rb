# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy
# For further information see the following documentation
# https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy

Rails.application.config.content_security_policy do |policy|
  policy.img_src :self, :https, :data
  # policy.default_src :self, :https
  # policy.font_src    :self, :https, :data
  # policy.object_src  :none
  # policy.script_src  :self, :https
  # policy.style_src   :self, :https, 'unsafe-inline'
  # policy.frame_src   'https://hcaptcha.com', 'https://*.hcaptcha.com'
  # policy.connect_src :self, :https, 'https://hcaptcha.com', 'https://*.hcaptcha.com'

  # If you are using webpack-dev-server then specify both the webpack-dev-server host
  # & the NodeJS crawler server:
  if Rails.env.development?
    policy.connect_src :self, :https, 'http://localhost:3035', 'ws://localhost:3035',
                                      'http://localhost:3001', # API on localhost
                                      'http://localhost:7000', 'ws://localhost:7000'
  else
    policy.connect_src :self, :https, 'http://localhost:7000', 'ws://localhost:7000'
  end

  # Specify URI for violation reports
  # policy.report_uri '/csp-violation-report-endpoint'
end

# If you are using UJS then enable automatic nonce generation
Rails.application.config.content_security_policy_nonce_generator = -> request { SecureRandom.base64(16) }

# Set the nonce only to specific directives
Rails.application.config.content_security_policy_nonce_directives = %w(script-src)

# Report CSP violations to a specified URI
# For further information see the following documentation:
# https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy-Report-Only
# Rails.application.config.content_security_policy_report_only = true
