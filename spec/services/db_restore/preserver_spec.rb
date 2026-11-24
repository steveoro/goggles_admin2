# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::Preserver do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:run) { create_restore_run(status: 'loading', user_id: admin_user.id, confirmations: { 'api_url_choice' => 'keep' }) }

  after(:each) { Ops::Database.reset_state! }

  it 'captures the API URL, the choice and the operator JWT before the drop' do
    preserved = described_class.capture!(run)
    expect(preserved).to include('api_url' => APIProxy.configured_base_url, 'api_url_choice' => 'keep', 'user_id' => admin_user.id,
                                 'jwt' => admin_user.jwt)
    expect(run.reload.preserved['captured_at']).to be_present
  end

  it 'keeps the first capture on a resumed run (MySQL may be half loaded)' do
    described_class.capture!(run)
    admin_user.update_columns(jwt: 'changed') # rubocop:disable Rails/SkipsModelValidations
    expect(described_class.capture!(run.reload)['jwt']).not_to eq('changed')
  end

  it 'falls back to keeping the current API URL for an unknown choice' do
    run.update!(confirmations: { 'api_url_choice' => 'whatever' })
    expect(described_class.capture!(run)['api_url_choice']).to eq('keep')
  end

  it 'never writes the JWT to the SQL log (capture and re-apply)' do
    run # (the spec's own user setup writes the JWT: before the log capture)
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    begin
      described_class.capture!(run)
      described_class.reapply!(run.reload)
    ensure
      ActiveRecord::Base.logger = original
    end
    expect(admin_user.jwt).to be_present
    expect(io.string).not_to include(admin_user.jwt)
  end

  it 're-applies the API URL and the JWT, then clears the JWT from the ops row' do
    described_class.capture!(run)
    original_url = APIProxy.configured_base_url
    cfg = GogglesDb::AppParameter.config
    cfg.settings(:framework_urls).value['api'] = 'https://elsewhere.example.test'
    cfg.save!
    admin_user.update_columns(jwt: 'from-the-dump') # rubocop:disable Rails/SkipsModelValidations
    outcome = described_class.reapply!(run.reload)
    expect(outcome).to eq('api_url' => 'kept', 'jwt' => 'applied')
    expect(APIProxy.configured_base_url).to eq(original_url)
    expect(admin_user.reload.jwt).not_to eq('from-the-dump')
    expect(run.reload.preserved).not_to have_key('jwt')
    expect(run.preserved['jwt_reapplied_at']).to be_present
  end
end
