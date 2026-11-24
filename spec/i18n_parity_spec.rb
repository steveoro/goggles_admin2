# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

RSpec.describe 'Locale files parity' do # rubocop:disable RSpec/DescribeClass
  def flatten_keys(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [prefix, key].compact.join('.')
      value.is_a?(Hash) ? flatten_keys(value, path) : [path]
    end
  end

  def keys_for(file)
    data = YAML.safe_load_file(file, aliases: true) || {}
    flatten_keys(data.values.first || {})
  end

  let(:en_files) { Rails.root.glob('config/locales/*.en.yml').sort }
  let(:it_files) { Rails.root.glob('config/locales/*.it.yml').sort }

  it 'has a partner file for every locale file' do
    en_names = en_files.map { |f| File.basename(f).sub('.en.yml', '') }
    it_names = it_files.map { |f| File.basename(f).sub('.it.yml', '') }
    expect(en_names - it_names).to eq([]), "missing .it.yml for: #{(en_names - it_names).join(', ')}"
    expect(it_names - en_names).to eq([]), "missing .en.yml for: #{(it_names - en_names).join(', ')}"
  end

  it 'has identical key sets in every en/it pair' do
    gaps = en_files.filter_map do |en_file|
      it_file = en_file.to_s.sub('.en.yml', '.it.yml')
      next unless File.exist?(it_file)

      en_keys = keys_for(en_file)
      it_keys = keys_for(it_file)
      next if en_keys.sort == it_keys.sort

      "#{File.basename(en_file)}: only in en: #{(en_keys - it_keys).first(20)}; only in it: #{(it_keys - en_keys).first(20)}"
    end
    expect(gaps).to eq([])
  end
end
