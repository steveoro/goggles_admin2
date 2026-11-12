# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::Notifier do
  describe '.ping' do
    it 'broadcasts an empty-html ping with the board DOM id on the app notifications stream' do
      allow(ActionCable.server).to receive(:broadcast)
      expect(described_class.ping).to be true
      expect(ActionCable.server).to have_received(:broadcast)
        .with(AppNotificationsChannel::STREAM, { dom_id: 'season-board-ping', html: '' })
    end

    it 'never raises (e.g. without a Solid Cable database)' do
      allow(ActionCable.server).to receive(:broadcast).and_raise(ActiveRecord::ConnectionNotEstablished, 'no cable db')
      expect(described_class.ping).to be false
    end
  end
end
