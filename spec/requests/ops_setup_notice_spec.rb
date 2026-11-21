# frozen_string_literal: true

require 'rails_helper'

# Layout notice shown while the local ops DB is not ready (see Ops::Database).
RSpec.describe 'Ops setup notice' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
  end

  after(:each) { Ops::Database.reset_state! }

  it 'is not shown when the ops DB is ready' do
    get(home_index_path)
    expect(response).to have_http_status(:success)
    expect(response.parsed_body.css('#ops-setup-notice')).to be_empty
  end

  %i[not_configured missing needs_migration].each do |state|
    it "is shown (instead of an error page) when the ops DB is #{state}" do
      allow(Ops::Database).to receive(:state).and_return(state)
      get(home_index_path)
      expect(response).to have_http_status(:success)
      notice = response.parsed_body.css('#ops-setup-notice')
      expect(notice.size).to eq(1)
      expect(notice.text).to include(I18n.t('ops.setup_notice.title'), I18n.t("ops.setup_notice.states.#{state}"), 'bin/rails ops:prepare')
    end
  end
end
