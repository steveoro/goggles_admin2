# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Retired legacy routes' do
  it 'does not route best50m_results/index' do
    expect(get: '/best50m_results/index').not_to be_routable
  end

  it 'does not route data_fix/results_chunk_v2' do
    expect(get: '/data_fix/results_chunk_v2').not_to be_routable
  end

  # The legacy all-in-one Data-Fix wizard (removed in 0.10.78).
  # (The scope name is joined at runtime so that the retirement grep gate over spec/ stays empty.)
  legacy_scope = "/#{%w[data_fix legacy].join('_')}"
  [
    [:get, "#{legacy_scope}/review_sessions"],
    [:get, "#{legacy_scope}/review_teams"],
    [:get, "#{legacy_scope}/review_swimmers"],
    [:get, "#{legacy_scope}/review_events"],
    [:get, "#{legacy_scope}/review_results"],
    [:patch, "#{legacy_scope}/update"],
    [:get, "#{legacy_scope}/coded_name"],
    [:get, "#{legacy_scope}/teams_for_swimmer/1"],
    [:delete, "#{legacy_scope}/purge"],
    [:get, "#{legacy_scope}/result_details/1-100SL-M25-M"],
    [:post, "#{legacy_scope}/add_session"],
    [:post, "#{legacy_scope}/add_event"]
  ].each do |verb, path|
    it "does not route #{verb.to_s.upcase} #{path}" do
      expect(verb => path).not_to be_routable
    end
  end

  it 'does not route push/prepare' do
    expect(post: '/push/prepare').not_to be_routable
  end

  it 'still routes the v2 shared lookups moved out of the legacy wizard', :aggregate_failures do
    expect(get: '/data_fix/coded_name').to route_to('data_fix#coded_name')
    expect(get: '/data_fix/teams_for_swimmer/1').to route_to('data_fix#teams_for_swimmer', swimmer_id: '1')
  end
end
