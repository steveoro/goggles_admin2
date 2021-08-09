# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationController, type: :request do
  let(:fixture_user) { GogglesDb::User.first(50).sample }
  before(:each) { expect(fixture_user).to be_a(GogglesDb::User).and be_valid }

  # Request Locale setter
  [nil, :it, :en, :invalid].each do |locale_sym|
    context "when setting the locale parameter as '#{locale_sym}'," do
      describe 'GET /' do
        context 'for an unlogged user' do
          it 'is a redirect to the login path' do
            get(root_path, params: { locale: locale_sym })
            expect(response).to redirect_to(new_user_session_path)
          end
          it 'sets the I18n locale' do
            expected_locale = locale_sym || :it
            expected_locale = I18n.default_locale if locale_sym == :invalid
            expect(I18n.locale).to eq(expected_locale)
          end
        end

        context 'for a logged-in user' do
          before(:each) do
            sign_in(fixture_user)
            get(root_path, params: { locale: locale_sym })
          end

          it 'returns http success' do
            expect(response).to have_http_status(:success)
          end
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
