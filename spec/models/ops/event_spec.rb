# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::Event do
  subject(:event) { FactoryBot.build(:ops_event) }

  it 'is valid with the factory defaults' do
    expect(event).to be_valid
  end

  it 'lives in the ops DB' do
    expect(described_class.connection_db_config.name).to eq('ops')
    expect(described_class.table_name).to eq('events')
  end

  it 'requires a kind and an occurred_at' do
    event.kind = nil
    event.occurred_at = nil
    expect(event).not_to be_valid
    expect(event.errors.attribute_names).to include(:kind, :occurred_at)
  end

  it 'restricts the level & actor values' do
    event.level = 'fatal'
    event.actor = 'robot'
    expect(event).not_to be_valid
    expect(event.errors.attribute_names).to include(:level, :actor)
  end

  it 'stores the data as JSON' do
    event.data = { 'files' => %w[a b], 'count' => 2 }
    event.save!
    expect(event.reload.data).to eq('files' => %w[a b], 'count' => 2)
  end

  it 'defaults the data to an empty Hash' do
    created = described_class.create!(kind: 'spec.no_data', occurred_at: Time.current)
    expect(created.reload).to have_attributes(data: {}, level: 'info', actor: 'system')
  end

  it 'lists the most recent first' do
    older = FactoryBot.create(:ops_event, occurred_at: 2.hours.ago)
    newer = FactoryBot.create(:ops_event, occurred_at: 1.hour.ago)
    expect(described_class.recent.where(id: [older.id, newer.id]).to_a).to eq([newer, older])
  end

  it 'filters by kind & subject' do
    match = FactoryBot.create(:ops_event, kind: 'board.crawl_finished', subject_type: 'fin_event', subject_key: '150100')
    FactoryBot.create(:ops_event, kind: 'board.crawl_finished', subject_type: 'fin_event', subject_key: '150101')
    expect(described_class.of_kind('board.crawl_finished').for_subject('fin_event', 150_100).to_a).to eq([match])
  end

  it 'has a localized title for every documented kind' do
    expect(FactoryBot.build(:ops_event, kind: 'datafix.committed').title).to eq(I18n.t('ops.events.datafix.committed'))
    expect(FactoryBot.build(:ops_event, kind: 'spec.unknown').title).to eq('spec.unknown')
  end
end
