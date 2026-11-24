# frozen_string_literal: true

require 'rails_helper'

# Phase 2 (Teams) "Team rankings" card, shown only when the Phase 2 data carries team_scores.
RSpec.describe DataFix::TeamsController do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:temp_dir) { Dir.mktmpdir }
  let(:source_file) { File.join(temp_dir, 'pdf_source-lt4.json') }
  let(:phase2_file) { source_file.sub('.json', '-phase2.json') }
  let(:season) { FactoryBot.create(:season) }
  let(:team) { FactoryBot.create(:team) }
  let(:phase2_data) do
    {
      'season_id' => season.id,
      'teams' => [
        { 'key' => 'Ranked Matched', 'name' => team.name, 'editable_name' => team.editable_name, 'team_id' => team.id, 'fuzzy_matches' => [] },
        { 'key' => 'Ranked New', 'name' => 'Ranked New', 'editable_name' => 'Ranked New', 'team_id' => nil, 'fuzzy_matches' => [] }
      ],
      'team_affiliations' => []
    }
  end

  before(:each) do
    sign_in_admin(admin_user)
    File.write(source_file, JSON.generate({ 'layoutType' => 4, 'teams' => {}, 'events' => [] }))
  end

  after(:each) { FileUtils.rm_rf(temp_dir) }

  def write_phase2(data)
    PhaseFileManager.new(phase2_file).write!(data:, meta: { 'generator' => 'test' })
  end

  it 'renders the team rankings card with the matched teams and a warning on unmatched keys', :aggregate_failures do
    write_phase2(phase2_data.merge('team_scores' => [
                                     { 'team_key' => 'Ranked Matched', 'rank' => 1, 'ind_score' => 35_209.93, 'overall_score' => 35_959.93 },
                                     { 'team_key' => 'Ranked New', 'rank' => 2, 'ind_score' => 0.0, 'overall_score' => 100.0 },
                                     { 'team_key' => 'Ranked Removed', 'rank' => 3, 'ind_score' => 1.0, 'overall_score' => 1.0 }
                                   ]))

    get review_teams_path(file_path: source_file, phase2_v2: 1)

    expect(response).to be_successful
    card = response.parsed_body.at_css('#phase2-team-scores-card')
    expect(card).to be_present
    expect(card.at_css('.card-header').text).to include("#{I18n.t('data_import.data_fix.team_scores.title')} (3)")
    rows = card.css('tbody tr')
    expect(rows.size).to eq(3)
    expect(rows[0].text).to include('Ranked Matched', "(ID: #{team.id})", '35209.93', '35959.93')
    expect(rows[0].text).not_to include(I18n.t('data_import.data_fix.team_scores.missing_team'))
    expect(rows[1].text).to include('Ranked New', I18n.t('data_import.data_fix.team_scores.missing_team'))
    expect(rows[2].text).to include('Ranked Removed', I18n.t('data_import.data_fix.team_scores.missing_team'))
  end

  it 'omits the card when the Phase 2 data has no team_scores' do
    write_phase2(phase2_data)

    get review_teams_path(file_path: source_file, phase2_v2: 1)

    expect(response).to be_successful
    expect(response.body).not_to include('phase2-team-scores-card')
  end
end
