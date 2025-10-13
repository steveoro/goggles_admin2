# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIMeetingReservationsController do
  describe 'GET api_meeting_reservations (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_meeting_reservations_path)
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
          method: :get, url: 'meeting_reservations', jwt: admin_user.jwt,
          params: {
            meeting_id: anything, swimmer_id: anything, team_id: anything,
            not_coming: anything,
            confirmed: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::MeetingReservation.first(25).to_json))
        get(api_meeting_reservations_path)
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'GET api_meeting_reservations/expand/:id (expand)' do
    let(:fixture_row) { GogglesDb::MeetingEventReservation.joins(:meeting_reservation).last(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        expect(fixture_row).to be_a(GogglesDb::MeetingEventReservation).and be_valid
        get(api_meeting_reservations_expand_path(id: fixture_row.meeting_reservation_id))
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
          method: :get,
          url: "meeting_reservation/#{fixture_row.meeting_reservation_id}",
          jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: fixture_row.to_json))
        get(api_meeting_reservations_expand_path(id: fixture_row.meeting_reservation_id))
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_meeting_reservations/:id (update)' do
    let(:fixture_row) { GogglesDb::MeetingEventReservation.joins(:meeting_reservation).last(200).sample.meeting_reservation }
    let(:new_value) { GogglesDb::Swimmer.pluck(:id).first(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        expect(fixture_row).to be_a(GogglesDb::MeetingReservation).and be_valid
        put(api_meeting_reservation_path(fixture_row.id), params: { swimmer_id: new_value })
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
            method: :put, url: "meeting_reservation/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_meeting_reservation_path(fixture_row.id), params: { swimmer_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        # Let's ignore filtering parameters in pass-through for brevity:
        expect(response.redirect_url).to include(api_meeting_reservations_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_meeting_reservations (create)' do
    let(:new_badge_id) { GogglesDb::Badge.pluck(:id).last(200).sample }
    let(:new_meeting_id) { GogglesDb::Meeting.pluck(:id).last(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(
          api_meeting_reservations_path,
          params: { badge_id: new_badge_id, meeting_id: new_meeting_id }
        )
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
            method: :post, url: 'meeting_reservation', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(
          api_meeting_reservations_path,
          params: { badge_id: new_badge_id, meeting_id: new_meeting_id }
        )
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        # Let's ignore filtering parameters in pass-through for brevity:
        expect(response.redirect_url).to include(api_meeting_reservations_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_meeting_reservations (destroy)' do
    let(:fixture_row) { FactoryBot.create(:meeting_reservation) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_meeting_reservations_destroy_path(id: fixture_row.id))
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      context 'when destroying a single row,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          # API double:
          allow(APIProxy).to receive(:call)
            .with(
              method: :delete, url: "meeting_reservation/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_meeting_reservations_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_meeting_reservations_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
