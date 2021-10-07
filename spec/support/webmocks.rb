# frozen_string_literal: true

require 'webmock/rspec'

RSpec.configure do |config|
  config.before(:each) do
    # == Note:
    # 1. Can't filter requests by headers:
    #
    #      .with(header: { 'Authorization' => 'Bearer <A_VALID_JWT>' })
    #
    #    This is due to the actual JWT checking in ApplicationController's before_action filter.
    #
    # 2. Can't filter requests by payload hash either:
    #
    #      .with(body: hash_including({ a_field: <UPDATE VALUE> }))
    #
    #    This is due to WebMock not being able to check partial body of a multi-part form POST.
    #
    # 3. Limit these to a minimum: each additional mock will add slower down significantly
    #    thet execution of any request spec.
    #
    #    => Use WebMocks ONLY for stubbing 'spec/strategies/api_proxy_spec.rb' <=
    #
    #    For all other tests, resort to use a <tt>class_double(APIProxy)</tt> instead,
    #    since it's way more faster.
    #
    api_base_url = GogglesDb::AppParameter.config.settings(:framework_urls).api

    # API stubs needed by spec/strategies/api_proxy_spec.rb:
    WebMock.stub_request(:post, "#{api_base_url}/api/v3/session")
           .with(body: { 'e' => 'admin-email', 'p' => 'fake-pwd', 't' => 'fake-token' })
           .to_return(
             status: 200,
             body: { 'msg': 'OK', 'jwt': '<A_VALID_JWT>' }.to_json
           )

    WebMock.stub_request(:get, %r{/api/v3/users}i)
           .to_return(status: 200, body: GogglesDb::User.first(50).to_a.to_json)

    WebMock.stub_request(:put, %r{/api/v3/user/\d}i)
           .to_return(status: 200, body: 'true')

    WebMock.stub_request(:delete, %r{/api/v3/import_queue/\d}i)
           .to_return(status: 200, body: 'true')
  end
end
