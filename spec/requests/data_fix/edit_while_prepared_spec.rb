# frozen_string_literal: true

require 'rails_helper'

# Phase 10: while a prepare job holds the source lease the review pages say "being prepared"; while any build holds it
# the edit actions, "Rebuild (discard edits)" and the category recompute are refused ("retry in a moment"), so a
# background build never races an operator write or delete.
RSpec.describe 'Data-Fix edits while a source is being prepared' do
  include AdminSignInHelpers

  let(:temp_dir) { Dir.mktmpdir }
  let(:source_file) { File.join(temp_dir, 'prep_source.json') }
  let(:phase2_file) { source_file.sub('.json', '-phase2.json') }
  let(:source_row) { Ops::PipelineSource.for_path!(source_file) }

  before(:each) do
    sign_in_admin(prepare_admin_user)
    File.write(source_file, JSON.generate({ 'layoutType' => 4, 'teams' => { 'Team A' => 'Team A' } }))
    PhaseFileManager.new(phase2_file).write!(data: { 'teams' => [{ 'key' => 'Team A', 'name' => 'Team A', 'team_id' => nil }] },
                                             meta: { 'generator' => 'test' })
  end

  after(:each) { FileUtils.rm_rf(temp_dir) }

  def update_team
    patch update_phase2_team_path, params: { file_path: source_file, team_key: 'Team A', team: { name: 'Team B' } },
                                   headers: { 'HTTP_REFERER' => review_teams_path(file_path: source_file, phase2_v2: 1) }
  end

  it 'refuses the edit while a prepare job holds the lease, leaving the phase file untouched' do
    source_row.acquire_lease!('job:abc', ttl: 10.minutes)
    before = File.binread(phase2_file)
    update_team
    expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))
    expect(flash[:warning]).to eq(I18n.t('pipeline_automation.review.edit_refused'))
    expect(File.binread(phase2_file)).to eq(before)
  end

  it 'refuses it while another request holds the lease too, and lets it through once the lease is released' do
    source_row.acquire_lease!('operator:1:x', ttl: 10.minutes)
    update_team
    expect(PhaseFileManager.new(phase2_file).data['teams'][0]['name']).to eq('Team A')
    source_row.release_lease!('operator:1:x')
    update_team
    expect(PhaseFileManager.new(phase2_file).data['teams'][0]['name']).to eq('Team B')
  end

  it 'refuses "Rebuild (discard edits)" and the category recompute while the lease is held (no phase deleted)' do
    source_row.acquire_lease!('job:abc', ttl: 10.minutes)
    post data_fix_discard_phase_edits_path, params: { file_path: source_file }
    expect(flash[:warning]).to eq(I18n.t('pipeline_automation.review.edit_refused'))
    post recompute_source_categories_path, params: { file_path: source_file }
    expect(flash[:warning]).to eq(I18n.t('pipeline_automation.review.edit_refused'))
    expect(File).to exist(phase2_file)
  end

  it 'shows "being prepared" on the review page' do
    source_row.acquire_lease!('job:abc', ttl: 10.minutes)
    get review_teams_path(file_path: source_file, phase2_v2: 1)
    expect(response.parsed_body.at_css('#data-fix-being-prepared')).to be_present
  end
end
