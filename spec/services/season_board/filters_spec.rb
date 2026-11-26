# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::Filters do
  def params(hash) = ActionController::Parameters.new(hash)

  describe '.explicit?' do
    it 'is true with the marker or any filter param, false otherwise' do
      expect(described_class.explicit?(params(filters: '1'))).to be true
      expect(described_class.explicit?(params(state: 'sql_pending'))).to be true
      expect(described_class.explicit?(params(show_done: '1'))).to be true
      expect(described_class.explicit?(params(locale: 'en', frame: '1', fin_event_id: '3'))).to be false
    end
  end

  describe '.from_params' do
    it 'keeps a known state and the present toggles, ignoring an unknown state' do
      expect(described_class.from_params(params(state: 'sql_pending', show_unlinked: '1')))
        .to have_attributes(state: 'sql_pending', show_unlinked: true, show_done: false)
      expect(described_class.from_params(params(state: 'drop_tables', filters: '1'))).to be_none
    end
  end

  describe '.load / #to_cookie' do
    it 'round-trips the filters through the cookie value' do
      filters = described_class.new(state: 'results_ready', show_unlinked: false, show_done: true)
      expect(filters.to_cookie).to eq('{"state":"results_ready","show_done":true}')
      expect(described_class.load(filters.to_cookie)).to eq(filters)
    end

    it 'gives no cookie value when nothing is filtered' do
      expect(described_class.none.to_cookie).to be_nil
    end

    it 'never raises on bytes that are not valid UTF-8 (a hand-made %FF cookie)' do
      expect(described_class.load(+"\xFF")).to be_none
      expect(described_class.load((+'{"state":"sql_pending"}').force_encoding(Encoding::ASCII_8BIT))).to have_attributes(state: 'sql_pending')
      expect(described_class.load(+"{\"state\":\"\xFF\"}")).to be_none
      expect(described_class.load(42)).to be_none
    end

    it 'ignores what it does not know' do
      expect(described_class.load(nil)).to be_none
      expect(described_class.load('{bad json')).to be_none
      expect(described_class.load('[1]')).to be_none
      expect(described_class.load({ 'state' => 'nope', 'show_done' => 'true', 'show_unlinked' => 1 }.to_json)).to be_none
      expect(described_class.load({ 'state' => 'sql_pending', 'x' => 'y' * 300 }.to_json)).to be_none
      expect(described_class.load({ 'state' => %w[sql_pending], 'show_done' => true, 'x' => 1 }.to_json))
        .to have_attributes(state: nil, show_done: true)
    end
  end
end
