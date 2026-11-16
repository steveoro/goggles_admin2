# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::CategoriesCache do
  let(:season) { GogglesDb::Season.find(242) }

  it 'loads serializable category snapshots without retaining ActiveRecord objects' do
    cache = described_class.new(
      season,
      category_types: [
        { 'id' => 70, 'code' => 'M70', 'age_begin' => 70, 'age_end' => 74, 'relay' => false, 'undivided' => false }
      ]
    )

    code, category = cache.find_category_for_age(72, relay: false)

    expect(code).to eq('M70')
    expect(category.id).to eq(70)
    expect(category.code).to eq('M70')
    expect(category).not_to be_a(GogglesDb::CategoryType)
  end

  it 'uses the Rails cache payload when building a seasonal cache' do
    categories = [instance_double(GogglesDb::CategoryType, id: 70, code: 'M70', age_begin: 70, age_end: 74,
                                                           relay?: false, undivided?: false)]
    allow(season).to receive(:category_types).and_return(categories)
    allow(Rails.cache).to receive(:fetch).and_return([
                                                       { 'id' => 70, 'code' => 'M70', 'age_begin' => 70, 'age_end' => 74, 'relay' => false, 'undivided' => false }
                                                     ])

    cache = described_class.cached_for(season)

    expect(Rails.cache).to have_received(:fetch).with(described_class.cache_key(season), expires_in: described_class::CACHE_EXPIRY, skip_nil: true)
    expect(cache['M70'].code).to eq('M70')
  end

  it 'falls back to the DB rows when the cache store raises' do
    category = instance_double(GogglesDb::CategoryType, id: 70, code: 'M70', age_begin: 70, age_end: 74,
                                                        relay?: false, undivided?: false)
    allow(season).to receive(:category_types).and_return([category])
    allow(Rails.cache).to receive(:fetch).and_raise(ActiveRecord::StatementInvalid, 'Could not find table')

    expect(described_class.cached_for(season)['M70']).to eq(category)
  end

  context 'with a real cache store' do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }
    let(:category) do
      instance_double(GogglesDb::CategoryType, id: 70, code: 'M70', age_begin: 70, age_end: 74,
                                               relay?: false, undivided?: false)
    end

    before(:each) { allow(Rails).to receive(:cache).and_return(store) }

    it 'stores the category list and reuses it on the next call' do
      allow(season).to receive(:category_types).and_return([category])
      described_class.cached_for(season)
      allow(season).to receive(:category_types).and_return([])

      expect(described_class.cached_for(season)['M70'].code).to eq('M70')
    end

    it 'never caches an empty category list' do
      allow(season).to receive(:category_types).and_return([])
      expect(described_class.cached_for(season).key?('M70')).to be false
      expect(store.exist?(described_class.cache_key(season))).to be false

      allow(season).to receive(:category_types).and_return([category])
      expect(described_class.cached_for(season)['M70'].code).to eq('M70')
    end
  end
end
