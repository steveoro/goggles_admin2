# frozen_string_literal: true

require 'rails_helper'

# The ready rule of DataFix::ReviewRules: one example per clause, on the spec/fixtures/data_fix/pipeline fixtures
# (verdicts of phases 1-3 computed by DataFix::Pipeline on a temporary copy).
RSpec.describe DataFix::ReviewRules do
  let(:tmp_dir) { Dir.mktmpdir('review-rules-') }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def verdicts_for(name)
    stub_valid_structure
    pipeline = pipeline_from_fixture(name, dir: tmp_dir)
    pipeline.relay_enrichment_count = 0
    (1..3).index_with { |phase| pipeline.verdict(phase) }
  end

  def codes(verdict) = verdict.issues.pluck('code')

  it 'clean_fin: clean and ready, listing the 2 new teams and the 37 new swimmers' do
    verdicts = verdicts_for('clean_fin')
    expect(verdicts.values.map(&:status)).to eq(%w[clean clean clean])
    expect(described_class.ready?(verdicts.values)).to be true
    expect(verdicts[2].new_teams.size).to eq(2)
    expect(verdicts[3].new_swimmers.size).to eq(37)
  end

  it 'new_meeting: review at step 1 (not matched by FIN id, not saved)' do
    verdicts = verdicts_for('new_meeting')
    expect(verdicts[1]).to be_review
    expect(codes(verdicts[1])).to include('meeting_not_fin_matched')
    expect(described_class.ready?(verdicts.values)).to be false
  end

  it 'team_candidate: review at step 2' do
    verdicts = verdicts_for('team_candidate')
    expect(verdicts[2]).to be_review
    expect(verdicts[2].issues.first).to include('code' => 'teams_review', 'count' => 1)
  end

  it 'grey_match_unconfirmed: review; grey_match_confirmed: clean' do
    expect(verdicts_for('grey_match_unconfirmed')[2]).to be_review
    expect(verdicts_for('grey_match_confirmed')[2]).to be_clean
  end

  it 'too_many_new_swimmers (41%): review at step 3' do
    verdict = verdicts_for('too_many_new_swimmers')[3]
    expect(verdict).to be_review
    expect(codes(verdict)).to eq(['too_many_new_swimmers'])
  end

  it 'too_many_new_teams (26%): review at step 2' do
    verdict = verdicts_for('too_many_new_teams')[2]
    expect(verdict).to be_review
    expect(codes(verdict)).to eq(['too_many_new_teams'])
  end

  it 'new_swimmer_missing_category: blocked at step 3 (not confidently new)' do
    verdict = verdicts_for('new_swimmer_missing_category')[3]
    expect(verdict).to be_blocked
    expect(codes(verdict)).to include('new_swimmer_incomplete')
    expect(verdict.new_swimmers).to be_empty
  end

  it 'gender_guessed: review at step 3 (the 89.9% value no longer hides it)' do
    verdict = verdicts_for('gender_guessed')[3]
    expect(verdict).to be_review
    expect(verdict.issues.first).to include('code' => 'swimmers_review', 'details' => ['M|FIXTUREZQ064|PIPELINE|1980'])
  end

  describe 'the row rules' do
    let(:new_team) { { 'team_id' => nil, 'fuzzy_matches' => [], 'similar_affiliated' => false } }
    let(:new_swimmer) { { 'swimmer_id' => nil, 'fuzzy_matches' => [], 'gender_type_code' => 'F', 'year_of_birth' => 1990, 'category_type_id' => 5 } }

    it 'does not send confidently-new entities to review, but keeps them in the review filter until confirmed' do
      expect(described_class.team_needs_review?(new_team)).to be false
      expect(described_class.team_in_review_filter?(new_team)).to be true
      expect(described_class.team_in_review_filter?(new_team.merge('confirmed' => true))).to be false
      expect(described_class.swimmer_needs_review?(new_swimmer)).to be false
      expect(described_class.swimmer_in_review_filter?(new_swimmer)).to be true
    end

    it 'reviews the teams with a candidate, a similar affiliated team or a Phase 3 conflict hint' do
      expect(described_class.team_needs_review?(new_team.merge('similar_affiliated' => true))).to be true
      expect(described_class.team_needs_review?(new_team.merge('fuzzy_matches' => [{ 'id' => 1 }]))).to be true
      hinted = { 'team_id' => 3, 'match_percentage' => 100.0, 'fuzzy_matches' => [{ 'id' => 4, 'from_phase3_conflict_hint' => true }] }
      expect(described_class.team_needs_review?(hinted)).to be true
      expect(described_class.team_needs_review?(hinted.merge('confirmed' => true))).to be false
    end

    it 'reviews the matches under the bar and the flagged swimmers unless confirmed' do
      matched = { 'swimmer_id' => 9, 'match_percentage' => 95.0 }
      expect(described_class.swimmer_needs_review?(matched)).to be false
      expect(described_class.swimmer_needs_review?(matched.merge('match_percentage' => 88.9))).to be true
      %w[gender_guessed auto_assigned_from_secondary_match has_badge_duplicates].each do |flag|
        expect(described_class.swimmer_needs_review?(matched.merge(flag => true))).to be(true), flag
      end
      expect(described_class.swimmer_needs_review?(matched.merge('gender_guessed' => true, 'confirmed' => true))).to be false
      expect(described_class.swimmer_needs_review?(new_swimmer.merge('fuzzy_matches' => [{ 'id' => 1 }]))).to be true
    end

    it 'applies the new-entity shares' do
      expect(described_class.too_many_new_teams?([new_team] + Array.new(3) { { 'team_id' => 1 } })).to be false # 25%
      expect(described_class.too_many_new_teams?([new_team] + Array.new(2) { { 'team_id' => 1 } })).to be true
      expect(described_class.too_many_new_swimmers?(Array.new(4, new_swimmer) + Array.new(6) { { 'swimmer_id' => 1 } })).to be false # 40%
    end
  end
end
