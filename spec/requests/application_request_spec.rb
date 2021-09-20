# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationController, type: :request do
  let(:fixture_user) { GogglesDb::User.first(50).sample }
  before(:each) { expect(fixture_user).to be_a(GogglesDb::User).and be_valid }

  # Request Locale setter
  [nil, :it, :en, :invalid].each do |locale_sym|
    context "when setting the locale parameter as '#{locale_sym}'," do
      describe 'GET /' do
        context 'with an unlogged user' do
          before(:each) { get(root_path, params: { locale: locale_sym }) }

          it 'is a redirect to the login path' do
            expect(response).to redirect_to(new_user_session_path)
          end

          it 'sets the I18n locale' do
            expected_locale = locale_sym || :it
            expected_locale = I18n.default_locale if locale_sym == :invalid
            expect(I18n.locale).to eq(expected_locale)
          end
        end

        context 'with a logged-in user' do
          include AdminSignInHelpers
          before(:each) do
            admin_user = prepare_admin_user
            sign_in_admin(admin_user)
            # API double:
            allow(APIProxy).to receive(:call).with(
              method: :get, url: anything, jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: (1..(rand * 200).to_i).to_a))
            get(root_path, params: { locale: locale_sym })
          end

          it 'returns http success' do
            expect(response).to have_http_status(:success)
          end

          it 'sets the I18n locale' do
            expected_locale = locale_sym || :it
            expected_locale = I18n.default_locale if locale_sym == :invalid
            expect(I18n.locale).to eq(expected_locale)
          end
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
