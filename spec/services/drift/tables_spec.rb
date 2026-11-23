# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Drift::Tables do
  it 'whitelists the 21 tables of tools/db_fingerprint, each with an owner class' do
    expect(described_class.all.size).to eq(21)
    expect(described_class.all).to include('laps', 'relay_laps', 'meetings', 'users', 'category_types')
    expect(described_class::OWNERS.values.uniq).to contain_exactly(:import, :user)
    expect(described_class.owner('laps')).to eq(:user)
    expect(described_class.import_owned?('meetings')).to be true
    expect(described_class.owner('nope')).to be_nil
  end

  it 'lists as commit tables only whitelisted tables Import::Committers::Main creates rows into' do
    expect(described_class::COMMIT_TABLES - described_class.all).to be_empty
    expect(described_class.commit_table?('laps')).to be true
    expect(described_class.commit_table?('users')).to be false
    committers = Rails.root.glob('app/strategies/import/committers/*.rb').map(&:read).join
    created = committers.scan(/GogglesDb::([A-Z]\w+)\.new/).flatten.uniq.map { |name| "GogglesDb::#{name}".constantize.table_name }
    expect(created).to match_array(described_class::COMMIT_TABLES)
  end

  it 'normalizes a table list to the whitelisted subset (all of them when blank)' do
    expect(described_class.normalize(nil)).to eq(described_class.all)
    expect(described_class.normalize('relay_laps, laps,nope')).to eq(%w[laps relay_laps])
    expect(described_class.normalize(%w[users])).to eq(%w[users])
  end
end
