# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::BackgroundCredentials do
  include AdminSignInHelpers

  let(:api_key) { Rails.application.credentials.api_static_key }
  let(:admin_user) { prepare_admin_user }

  after(:each) { Ops::Database.reset_state! }

  describe '.remember! and the stored user' do
    it 'stores the user ID in the background.user_id setting and uses that user' do
      expect(described_class.remember!(admin_user)).to eq(admin_user.id)
      expect(Ops::Setting.fetch('background.user_id')).to eq(admin_user.id)
      credentials = described_class.new
      expect(credentials.user).to eq(admin_user)
      expect(credentials.status).to eq(:valid)
      expect(credentials.jwt).to eq(admin_user.jwt)
      expect(described_class.jwt).to eq(admin_user.jwt)
      expect(described_class.status).to eq(:valid)
    end

    it 'reports the expiry time from the token exp claim' do
      described_class.remember!(admin_user)
      expect(described_class.new.expires_at).to be_within(1.minute).of(GogglesDb::JWTManager::TOKEN_LIFE.from_now)
    end

    it 'never raises with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect(described_class.remember!(admin_user)).to be_nil
    end
  end

  describe 'fallback user' do
    it 'uses the admin with a JWT and the latest sign-in when no user is stored' do
      older = prepare_admin_user
      older.update!(current_sign_in_at: 2.days.ago)
      admin_user.update!(current_sign_in_at: 1.minute.ago)
      expect(described_class.new.user).to eq(admin_user)
    end

    it 'ignores a stored user that is no longer an admin' do
      plain_user = FactoryBot.create(:user)
      Ops::Setting.store!('background.user_id', plain_user.id)
      admin_user.update!(current_sign_in_at: Time.current)
      expect(described_class.new.user).to eq(admin_user)
    end
  end

  describe '#status' do
    before(:each) { described_class.remember!(admin_user) }

    it 'is :expired (and the JWT nil) for an expired token' do
      admin_user.update!(jwt: GogglesDb::JWTManager.encode({ user_id: admin_user.id }, api_key, -1.minute))
      credentials = described_class.new
      expect(credentials.status).to eq(:expired)
      expect(credentials.jwt).to be_nil
      expect(credentials.expires_at).to be_nil
    end

    it 'is :expired for a token signed with another key' do
      admin_user.update!(jwt: GogglesDb::JWTManager.encode({ user_id: admin_user.id }, 'another-key'))
      expect(described_class.new.status).to eq(:expired)
    end

    it 'is :missing without a token' do
      admin_user.update!(jwt: nil)
      expect(described_class.new.status).to eq(:missing)
      expect(described_class.jwt).to be_nil
    end
  end
end
