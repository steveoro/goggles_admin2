# frozen_string_literal: true

require 'capybara/rspec'
require 'selenium-webdriver'

# = System test helpers (browser-level smoke specs under spec/system)
#
# - Headless Chrome through Selenium (binary from ENV['CHROME_BIN'] when set).
# - Needs network access: until the assets are vendored the layout loads Bootstrap, FontAwesome,
#   jQuery & friends from CDNs (WebMock doesn't affect the browser).
# - Run <tt>bin/rails dartsass:build</tt> once before the first run.
# - Set ENV['SKIP_SYSTEM'] (any non-empty value) to exclude the whole `type: :system` group.
#
# Also keeps out of the way of guard (see the Guardfile: `-t ~type:system`).
#
Capybara.register_driver(:goggles_headless_chrome) do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.binary = ENV.fetch('CHROME_BIN', nil) if ENV['CHROME_BIN'].to_s.present?
  %w[--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --window-size=1400,1000].each do |arg|
    options.add_argument(arg)
  end
  options.add_option('goog:loggingPrefs', { browser: 'ALL' })
  Capybara::Selenium::Driver.new(app, browser: :chrome, options:)
end

# Capybara 3.40 resets Chrome with a CDP 'Storage.clearDataForOrigin' using origin '*', which newer
# Chrome versions reject ("* is not a valid URL"). Cookies are cleared by the regular reset anyway.
module GogglesChromeResetPatch
  private

  def execute_cdp(cmd, params = {})
    return if cmd == 'Storage.clearDataForOrigin'

    super
  end
end
Capybara::Selenium::Driver.prepend(
  Module.new do
    def browser
      first_time = @browser.nil?
      super.tap { extend(GogglesChromeResetPatch) if first_time }
    end
  end
)
Capybara.default_max_wait_time = 8
Capybara.server = :puma, { Silent: true }

# Helpers for browser-level journeys
module SystemTestHelpers
  # Browser console messages that are not considered an application error:
  IGNORED_JS_LOG_PATTERNS = [
    /favicon\.ico/i,
    /Failed to load resource: the server responded with a status of 404/i
  ].freeze

  # Signs-in through the actual form, using the default factory password.
  def sign_in_through_form(user, password: 'Password123!')
    visit(new_user_session_path)
    fill_in('user_email', with: user.email)
    fill_in('user_password', with: password)
    click_button('login-btn')
  end

  # Returns the SEVERE browser console entries (messages only) collected so far, minus the ignored ones.
  # NOTE: reading the log consumes it.
  def severe_js_log_messages
    entries = page.driver.browser.logs.get(:browser)
    entries.select { |entry| entry.level == 'SEVERE' }
           .map(&:message)
           .grep_v(Regexp.union(IGNORED_JS_LOG_PATTERNS))
  end

  # Stubs the API endpoints behind the Stats page (also hit by Turbo prefetching of the home KPI card).
  def stub_stats_api(rows: [])
    allow(APIProxy).to receive(:call).with(hash_including(url: 'api_daily_uses', params: anything))
                                     .and_return(DummyResponse.new(body: rows.to_json))
    allow(APIProxy).to receive(:call).with(hash_including(url: 'api_daily_uses/summary'))
                                     .and_return(DummyResponse.new(body: {
                                       'top_routes' => [], 'top_ips' => [], 'top_agents' => [],
                                       'daily_agents' => [], 'totals' => {}
                                     }.to_json))
  end

  # Fails when the browser console reported any SEVERE message since the last check.
  def expect_no_js_errors
    expect(severe_js_log_messages).to be_empty
  end

  # Waits until no Bootstrap modal backdrop is left on the page.
  def expect_no_modal_backdrop
    expect(page).to have_no_css('.modal-backdrop', wait: 5)
  end
end

RSpec.configure do |config|
  config.include(Devise::Test::IntegrationHelpers, type: :system)
  config.include(AdminSignInHelpers, type: :system)
  config.include(SystemTestHelpers, type: :system)

  config.filter_run_excluding(type: :system) if ENV['SKIP_SYSTEM'].to_s.present?

  config.before(:each, type: :system) do
    driven_by(:goggles_headless_chrome)
    # Default API double (individual journeys override it as needed):
    allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: '[]'))
    stub_stats_api
  end
end
