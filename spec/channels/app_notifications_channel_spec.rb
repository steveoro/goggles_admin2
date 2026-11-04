# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AppNotificationsChannel do
  it 'subscribes to the app-wide notifications stream' do
    subscribe
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(described_class::STREAM)
  end
end
