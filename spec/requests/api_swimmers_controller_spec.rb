# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APISwimmersController, type: :request do
  describe 'GET api_swimmers (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_swimmers_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'swimmers', jwt: admin_user.jwt,
          params: { page: anything, per_page: anything }
        ).and_return(DummyResponse.new(body: GogglesDb::Swimmer.first(25).to_json))
      end

      it 'returns http success' do
        get(api_swimmers_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_swimmer (update)' do
    let(:fixture_row) { FactoryBot.create(:swimmer) }
    let(:new_value) { FFaker::Lorem.word.capitalize }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_swimmer_path(fixture_row.id), params: { first_name: new_value })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :put, url: "swimmer/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_swimmer_path(fixture_row.id), params: { description: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_swimmers_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_swimmers (create)' do
    let(:new_attributes) { FactoryBot.build(:swimmer).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_swimmers_path, params: new_attributes)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :post, url: 'swimmer', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: -1 } }.to_json))
        post(api_swimmers_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_swimmers_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
