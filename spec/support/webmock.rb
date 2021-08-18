# frozen_string_literal: true

require 'webmock/rspec'

RSpec.configure do |config|
  config.before(:each) do
    # API /session
    WebMock.stub_request(:post, %r{/api/v3/session}i)
           .with(body: { 'e' => 'admin-email', 'p' => 'fake-pwd', 't' => 'fake-token' })
           .to_return(
             status: 200,
             body: { 'msg': 'OK', 'jwt': '<A_VALID_JWT>' }.to_json
           )

    # API /users
    WebMock.stub_request(:get, %r{/api/v3/users}i)
           .with(headers: { 'Authorization' => 'Bearer <A_VALID_JWT>' })
           .to_return(
             status: 200,
             body: GogglesDb::User.all.to_a.to_json
           )
  end
end
