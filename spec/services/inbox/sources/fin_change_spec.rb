# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::FINChange do
  include InboxSummaryFixtures

  let(:store) { FedernuotoWatch::StateStore.new }

  before(:each) { FileUtils.rm_f(store.path) }
  after(:each) { FileUtils.rm_f(store.path) }

  it 'has the :fin_change key and emits nothing without a pending change' do
    expect(described_class.key).to eq(:fin_change)
    expect(described_class.new.items(inbox_context)).to eq([])
  end

  it 'emits one notice opening the board, waiting since the first detection' do
    first = 2.days.ago.change(usec: 0)
    store.update do |state|
      state.merge('change' => { 'detected_at' => Time.current.iso8601, 'first_detected_at' => first.iso8601,
                                'added' => [{ 'name' => 'New one' }], 'with_results' => [{ 'name' => 'Done one' }] })
    end
    item = described_class.new.items(inbox_context).first
    expect(item).to have_attributes(key: 'fin_change', band: :notice, since: first)
    expect(item.title).to eq(I18n.t('inbox.fin_change.title', count: 2))
    expect(item.action.path).to eq('/season_board')
  end
end
