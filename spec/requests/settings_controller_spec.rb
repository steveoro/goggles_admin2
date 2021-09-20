# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Settings', type: :request do
  # describe 'GET /index' do
  #   context 'with an unlogged user' do
  #     it 'is a redirect to the login path' do
  #       get(settings_path)
  #       expect(response).to redirect_to(new_setting_session_path)
  #     end
  #   end

  #   context 'with a logged-in user' do
  #     include AdminSignInHelpers
  #     before(:each) do
  #       admin_setting = prepare_admin_setting
  #       sign_in_admin(admin_setting)
  #       # API double:
  #       allow(APIProxy).to receive(:call).with(
  #         method: :get, url: 'settings', jwt: admin_setting.jwt,
  #         params: { page: anything, per_page: anything }
  #       ).and_return(DummyResponse.new(body: GogglesDb::User.all.to_json))
  #     end

  #     it 'returns http success' do
  #       get(settings_path)
  #       expect(response).to have_http_status(:success)
  #     end
  #   end
  # end
  # #-- -------------------------------------------------------------------------
  # #++

  # describe 'PUT /update' do
  #   let(:fixture_row) { FactoryBot.create(:setting) }
  #   let(:new_value) { "#{FFaker::Name.first_name} #{FFaker::Name.last_name}" }

  #   context 'with an unlogged user' do
  #     it 'is a redirect to the login path' do
  #       put(setting_path(fixture_row.id), params: { complete_name: new_value })
  #       expect(response).to redirect_to(new_setting_session_path)
  #     end
  #   end

  #   context 'with a logged-in user' do
  #     include AdminSignInHelpers
  #     before(:each) do
  #       admin_setting = prepare_admin_setting
  #       sign_in_admin(admin_setting)
  #       # API double:
  #       allow(APIProxy).to receive(:call)
  #         .with(
  #           method: :put, url: "setting/#{fixture_row.id}", jwt: admin_setting.jwt,
  #           payload: anything
  #         ).and_return(DummyResponse.new(body: 'true'))
  #       put(setting_path(fixture_row.id), params: { complete_name: new_value })
  #     end

  #     it 'sets the flash success message' do
  #       expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
  #     end

  #     it 'does NOT set the flash error message' do
  #       expect(flash[:error]).to be nil
  #     end

  #     it 'redirects to /index' do
  #       expect(response).to redirect_to(settings_path)
  #     end
  #   end
  # end
  # #-- -------------------------------------------------------------------------
  # #++

  # describe 'DELETE /destroy' do
  #   let(:fixture_row) { FactoryBot.create(:setting) }

  #   context 'with an unlogged user' do
  #     it 'is a redirect to the login path' do
  #       delete(settings_destroy_path(id: fixture_row.id))
  #       expect(response).to redirect_to(new_setting_session_path)
  #     end
  #   end

  #   context 'with a logged-in user' do
  #     include AdminSignInHelpers
  #     before(:each) do
  #       admin_setting = prepare_admin_setting
  #       sign_in_admin(admin_setting)
  #       # API double:
  #       allow(APIProxy).to receive(:call)
  #         .with(
  #           method: :delete, url: "setting/#{fixture_row.id}", jwt: admin_setting.jwt
  #         ).and_return(DummyResponse.new(body: 'true'))
  #       delete(settings_destroy_path(id: fixture_row.id))
  #     end

  #     it 'sets the flash success message' do
  #       expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
  #     end

  #     it 'does NOT set the flash error message' do
  #       expect(flash[:error]).to be nil
  #     end

  #     it 'redirects to /index' do
  #       expect(response).to redirect_to(settings_path)
  #     end
  #   end
  # end
  #-- -------------------------------------------------------------------------
  #++
end
