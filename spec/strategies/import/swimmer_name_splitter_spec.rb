# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::SwimmerNameSplitter do
  describe '.split_complete_name' do
    it 'splits common italian particles in 3-token names' do
      last_name, first_name, complete_name = described_class.split_complete_name('DE ROSA GABRIELE')

      expect(last_name).to eq('DE ROSA')
      expect(first_name).to eq('GABRIELE')
      expect(complete_name).to eq('DE ROSA GABRIELE')
    end

    it 'keeps two-token surname assumption for longer names' do
      last_name, first_name, complete_name = described_class.split_complete_name('PANTANETTI SABATINI ELIA')

      expect(last_name).to eq('PANTANETTI')
      expect(first_name).to eq('SABATINI ELIA')
      expect(complete_name).to eq('PANTANETTI SABATINI ELIA')
    end
  end

  describe '.resolve_parts' do
    it 're-splits ambiguous particle surname + multi-token first name' do
      last_name, first_name, complete_name = described_class.resolve_parts(
        last_name: 'DE',
        first_name: 'ROSA GABRIELE',
        complete_name: 'DE ROSA GABRIELE'
      )

      expect(last_name).to eq('DE ROSA')
      expect(first_name).to eq('GABRIELE')
      expect(complete_name).to eq('DE ROSA GABRIELE')
    end
  end
end
