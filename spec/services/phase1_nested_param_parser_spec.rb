# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Phase1NestedParamParser do
  describe '.parse' do
    let(:allowed_keys) { %w[id swimming_pool_id name nick_name address latitude longitude] }

    context 'with mixed nested and top-level parameters' do
      it 'merges both structures correctly' do
        params = ActionController::Parameters.new({
                                                    '0' => { 'swimming_pool_id' => '123', 'latitude' => '45.123' },
                                                    'name' => 'Test Pool',
                                                    'address' => '123 Main St',
                                                    'longitude' => '12.456'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({
                               'swimming_pool_id' => '123',
                               'latitude' => '45.123',
                               'name' => 'Test Pool',
                               'address' => '123 Main St',
                               'longitude' => '12.456'
                             })
      end

      it 'nested params take precedence over top-level params for same key' do
        params = ActionController::Parameters.new({
                                                    '0' => { 'name' => 'Nested Name' },
                                                    'name' => 'Top Level Name'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result['name']).to eq('Nested Name')
      end
    end

    context 'with only nested indexed parameters' do
      it 'extracts nested parameters correctly' do
        params = ActionController::Parameters.new({
                                                    '0' => {
                                                      'id' => '456',
                                                      'name' => 'Nested Pool',
                                                      'address' => 'Nested Address'
                                                    }
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({
                               'id' => '456',
                               'name' => 'Nested Pool',
                               'address' => 'Nested Address'
                             })
      end

      it 'handles integer index key' do
        params = ActionController::Parameters.new({
                                                    0 => { 'name' => 'Integer Index' }
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result['name']).to eq('Integer Index')
      end

      it 'handles string index key' do
        params = ActionController::Parameters.new({
                                                    '2' => { 'name' => 'String Index' }
                                                  })

        result = described_class.parse(params, allowed_keys, '2')

        expect(result['name']).to eq('String Index')
      end
    end

    context 'with only top-level parameters' do
      it 'extracts top-level parameters correctly' do
        params = ActionController::Parameters.new({
                                                    'name' => 'Top Level Pool',
                                                    'address' => 'Top Level Address',
                                                    'latitude' => '45.0',
                                                    'longitude' => '12.0'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({
                               'name' => 'Top Level Pool',
                               'address' => 'Top Level Address',
                               'latitude' => '45.0',
                               'longitude' => '12.0'
                             })
      end
    end

    context 'with unpermitted keys' do
      it 'filters out keys not in allowed_keys' do
        params = ActionController::Parameters.new({
                                                    'name' => 'Allowed',
                                                    'evil_param' => 'Not Allowed',
                                                    'another_bad_key' => 'Nope'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({ 'name' => 'Allowed' })
        expect(result).not_to have_key('evil_param')
        expect(result).not_to have_key('another_bad_key')
      end

      it 'filters nested unpermitted keys' do
        params = ActionController::Parameters.new({
                                                    '0' => {
                                                      'name' => 'Allowed',
                                                      'hacker_field' => 'Not Allowed'
                                                    }
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({ 'name' => 'Allowed' })
        expect(result).not_to have_key('hacker_field')
      end
    end

    context 'with edge cases' do
      it 'returns empty hash for nil params' do
        result = described_class.parse(nil, allowed_keys, 0)

        expect(result).to eq({})
      end

      it 'returns empty hash for non-Parameters object' do
        result = described_class.parse({ 'name' => 'Regular Hash' }, allowed_keys, 0)

        expect(result).to eq({})
      end

      it 'returns empty hash when no matching index exists' do
        params = ActionController::Parameters.new({
                                                    '0' => { 'name' => 'Index 0' },
                                                    '1' => { 'name' => 'Index 1' }
                                                  })

        result = described_class.parse(params, allowed_keys, 5)

        expect(result).to eq({})
      end

      it 'handles empty ActionController::Parameters' do
        params = ActionController::Parameters.new({})

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({})
      end

      it 'handles nested hash that is not Parameters' do
        params = ActionController::Parameters.new({
                                                    '0' => 'not a hash',
                                                    'name' => 'Top Level'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result).to eq({ 'name' => 'Top Level' })
      end
    end

    context 'with real-world AutoComplete + form scenario' do
      it 'handles AutoComplete ID field + manual form fields' do
        # AutoComplete sends: pool[0][swimming_pool_id] = "22"
        # Form fields send: pool[name], pool[address], etc.
        params = ActionController::Parameters.new({
                                                    '0' => { 'swimming_pool_id' => '22' },
                                                    'name' => 'Stadio Comunale',
                                                    'nick_name' => 'stadio-comunale',
                                                    'address' => 'Via dello Sport 1',
                                                    'latitude' => '44.123456',
                                                    'longitude' => '11.654321'
                                                  })

        result = described_class.parse(params, allowed_keys, 0)

        expect(result['swimming_pool_id']).to eq('22')
        expect(result['name']).to eq('Stadio Comunale')
        expect(result['nick_name']).to eq('stadio-comunale')
        expect(result['address']).to eq('Via dello Sport 1')
        expect(result['latitude']).to eq('44.123456')
        expect(result['longitude']).to eq('11.654321')
      end

      it 'handles city AutoComplete + form fields' do
        params = ActionController::Parameters.new({
                                                    '1' => { 'id' => '789' },
                                                    'name' => 'Bologna',
                                                    'address' => 'Provincia di Bologna'
                                                  })

        city_keys = %w[id city_id name area address]
        result = described_class.parse(params, city_keys, 1)

        expect(result['id']).to eq('789')
        expect(result['name']).to eq('Bologna')
        expect(result['address']).to eq('Provincia di Bologna')
      end
    end
  end
end
