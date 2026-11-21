# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Retired legacy routes' do
  it 'does not route best50m_results/index' do
    expect(get: '/best50m_results/index').not_to be_routable
  end

  it 'does not route data_fix/results_chunk_v2' do
    expect(get: '/data_fix/results_chunk_v2').not_to be_routable
  end
end
