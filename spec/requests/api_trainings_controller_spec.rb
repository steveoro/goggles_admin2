# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APITrainingsController do
  let(:api_row) do
    {
      'id' => 42, 'title' => '2026-10-03 Coach B.', 'training_date' => '2026-10-03T09:30:00.000Z',
      'training_by' => 'Coach B.', 'created_by' => 'Steve A.', 'swimmer_id' => 1,
      'description' => "4x100 FR\n2x200 IM", 'picture_filename' => '20261003_142.jpg',
      'image_path' => '/rails/active_storage/blobs/redirect/xyz/pic.jpg',
      'image_thumb_path' => '/rails/active_storage/representations/redirect/abc/pic.jpg',
      'image_missing' => false
    }
  end

  describe 'GET api_trainings (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_trainings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'trainings', jwt: admin_user.jwt,
          params: { page: 1, per_page: 25 }
        ).and_return(DummyResponse.new(body: [api_row, api_row.merge('id' => 43, 'image_missing' => true)].to_json))
        get(api_trainings_path)
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end

      it 'renders the rows with their fields' do
        expect(response.body).to include('Coach B.').and include('20261003_142.jpg')
      end

      it 'flags the missing-image rows' do
        expect(response.body).to include(I18n.t('api_trainings.image_missing'))
      end
    end

    context 'when the API fails with a non-JSON error body' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        fake_result = APIProxy::Result.new(
          double(code: 503, body: 'Service Unavailable', headers: {})
        )
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'trainings', jwt: admin_user.jwt,
          params: { page: 1, per_page: 25 }
        ).and_return(fake_result)
        get(api_trainings_path)
      end

      it 'redirects to the dashboard with an error flash instead of raising' do
        expect(response).to redirect_to(root_path)
        expect(flash[:error]).to be_present
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'GET new api_training' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(new_api_training_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      it 'returns http success' do
        sign_in_admin(prepare_admin_user)
        get(new_api_training_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_trainings (create)' do
    let(:form_params) do
      {
        training: {
          training_by: 'Coach B.', created_by: 'Steve A.',
          training_date: '2026-10-03T09:30', description: '4x100 FR'
        },
        swimmer_id: '1'
      }
    end

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_trainings_path, params: form_params)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      context 'when the API responds with a successful creation,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          allow(APIProxy).to receive(:call).with(
            method: :post, url: 'training', jwt: admin_user.jwt,
            payload: hash_including('training_by' => 'Coach B.', 'swimmer_id' => '1')
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 42 } }.to_json))
          post(api_trainings_path, params: form_params)
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.create_ok', id: 42))
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_trainings_path)
        end
      end

      context 'when the API responds with an error,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          allow(APIProxy).to receive(:call).with(
            method: :post, url: 'training', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { error: 'invalid' }.to_json))
          post(api_trainings_path, params: form_params)
        end

        it 'sets the flash error message' do
          expect(flash[:error]).to be_present
        end

        it 'redirects back to /new' do
          expect(response).to redirect_to(new_api_training_path)
        end
      end

      context 'when an image file is attached to the form,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          allow(APIProxy).to receive(:call).and_return(
            DummyResponse.new(body: { msg: 'OK', new: { id: 44 } }.to_json)
          )
          post(
            api_trainings_path,
            params: form_params.deep_merge(
              training: {
                image: Rack::Test::UploadedFile.new(
                  Rails.root.join('spec/fixtures/files/test_training.png'), 'image/png'
                )
              }
            )
          )
        end

        it 'forwards the uploaded file inside the API payload' do
          expect(APIProxy).to have_received(:call).with(
            method: :post, url: 'training', jwt: anything,
            payload: hash_including('image' => a_kind_of(ActionDispatch::Http::UploadedFile))
          )
        end
      end

      context 'when the API rejection carries an X-Error-Detail header,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          fake_result = APIProxy::Result.new(
            double(
              code: 422, body: { error: 'generic' }.to_json,
              headers: { x_error_detail: ":image content type 'text/plain' not allowed" }
            )
          )
          allow(APIProxy).to receive(:call).and_return(fake_result)
          post(api_trainings_path, params: form_params)
        end

        it 'shows the detailed reason in the flash error' do
          expect(flash[:error]).to include('content type')
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'GET edit api_training' do
    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:call).with(
          method: :get, url: "training/#{api_row['id']}", jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: api_row.to_json))
        allow(APIProxy).to receive(:call).with(
          method: :get, url: "swimmer/#{api_row['swimmer_id']}", jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: { 'id' => 1, 'complete_name' => 'ALLORO STEFANO' }.to_json))
        get(edit_api_training_path(api_row['id']))
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end

      it 'prefills the form values' do
        expect(response.body).to include('Coach B.').and include('4x100 FR')
      end
    end

    context 'when the row does not exist' do
      include AdminSignInHelpers

      it 'redirects to /index with an error' do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'training/9999', jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: ''))
        get(edit_api_training_path(9999))
        expect(response).to redirect_to(api_trainings_path)
        expect(flash[:error]).to be_present
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_training (update)' do
    context 'with a logged-in user' do
      include AdminSignInHelpers

      context 'when the API update succeeds,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          allow(APIProxy).to receive(:call).with(
            method: :put, url: "training/#{api_row['id']}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: api_row.to_json))
          put(api_training_path(api_row['id']), params: { training: { training_by: 'New Coach' } })
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_trainings_path)
        end
      end

      context 'when the API update fails,' do
        it 'sets the flash error message' do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          allow(APIProxy).to receive(:call).with(
            method: :put, url: "training/#{api_row['id']}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: ''))
          put(api_training_path(api_row['id']), params: { training: { training_by: 'New Coach' } })
          expect(flash[:error]).to be_present
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_training (destroy)' do
    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:call).with(
          method: :delete, url: "training/#{api_row['id']}", jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: 'true'))
        delete(api_training_path(api_row['id']))
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: "[#{api_row['id']}]"))
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_trainings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
