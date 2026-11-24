# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe Import::TeamScoreExtractor do
  let(:ranking_rows) do
    [
      { 'pos' => '2', 'team' => 'Team B', 'ind_score' => '35004.290', 'overall_score' => '35004.290' },
      { 'pos' => '1', 'team' => 'Team A', 'ind_score' => '35209.930', 'overall_score' => '36209.930' },
      { 'pos' => '3', 'team' => 'Team C', 'ind_score' => nil, 'overall_score' => '30981.85' }
    ]
  end
  let(:lt2_hash) do
    {
      'layoutType' => 2,
      'sections' => [
        { 'title' => '50 SL', 'fin_sesso' => 'M', 'rows' => [{ 'pos' => 1, 'name' => 'ROSSI MARIO', 'team' => 'Team A' }] },
        { 'title' => 'Overall Team Ranking', 'ranking' => true, 'rows' => ranking_rows },
        { 'title' => 'Overall Stats', 'stats' => true, 'rows' => [{ 'stats_label' => 'Teams', 'stats_value' => '3' }] }
      ]
    }
  end
  let(:expected_scores) do
    [
      { 'team_key' => 'Team A', 'rank' => 1, 'ind_score' => 35_209.93, 'overall_score' => 36_209.93 },
      { 'team_key' => 'Team B', 'rank' => 2, 'ind_score' => 35_004.29, 'overall_score' => 35_004.29 },
      { 'team_key' => 'Team C', 'rank' => 3, 'ind_score' => 0.0, 'overall_score' => 30_981.85 }
    ]
  end

  describe '.extract' do
    it 'reads the LT4 teamRankings array, sorted by rank' do
      expect(described_class.extract({ 'layoutType' => 4, 'events' => [], 'teamRankings' => ranking_rows })).to eq(expected_scores)
    end

    it 'reads the LT2 sections flagged as ranking (ignoring results & stats sections)' do
      expect(described_class.extract(lt2_hash)).to eq(expected_scores)
    end

    it 'deduplicates on the legacy "rank-team" key (first row wins), keeping same team on other ranks' do
      rows = [
        { 'pos' => '1', 'team' => 'Team A', 'ind_score' => '10', 'overall_score' => '10' },
        { 'pos' => '1', 'team' => 'Team A', 'ind_score' => '99', 'overall_score' => '99' },
        { 'pos' => '2', 'team' => 'Team A', 'ind_score' => '5', 'overall_score' => '5' },
        { 'pos' => '3', 'team' => '', 'ind_score' => '1', 'overall_score' => '1' }
      ]
      result = described_class.extract({ 'teamRankings' => rows })

      expect(result.map { |score| [score['rank'], score['team_key'], score['ind_score']] })
        .to eq([[1, 'Team A', 10.0], [2, 'Team A', 5.0]])
    end

    it 'parses the score formats found in the PDF-derived files' do
      rows = [
        { 'pos' => '1', 'team' => 'T1', 'ind_score' => '35209.930', 'overall_score' => '1.234,50' },
        { 'pos' => '2', 'team' => 'T2', 'ind_score' => '792,89', 'overall_score' => "1'044.06" }
      ]
      result = described_class.extract({ 'teamRankings' => rows })

      expect(result.map { |score| [score['ind_score'], score['overall_score']] }).to eq([[35_209.93, 1234.5], [792.89, 1044.06]])
    end

    it 'returns an empty list without rankings' do
      expect(described_class.extract({ 'layoutType' => 4, 'events' => [] })).to eq([])
      expect(described_class.extract({ 'sections' => [lt2_hash['sections'].first] })).to eq([])
      expect(described_class.extract(nil)).to eq([])
    end
  end

  describe '.from_source' do
    it 'falls back to the LT2 sibling when an LT4 working copy has no teamRankings' do
      Dir.mktmpdir do |tmp|
        lt4_path = File.join(tmp, 'meeting-lt4.json')
        File.write(File.join(tmp, 'meeting.json'), JSON.generate(lt2_hash))

        expect(described_class.from_source(lt4_path, { 'layoutType' => 4, 'events' => [] })).to eq(expected_scores)
      end
    end

    it 'prefers the teamRankings of the LT4 working copy over the LT2 sibling' do
      Dir.mktmpdir do |tmp|
        lt4_path = File.join(tmp, 'meeting-lt4.json')
        File.write(File.join(tmp, 'meeting.json'), JSON.generate(lt2_hash))
        rows = [{ 'pos' => '1', 'team' => 'Edited', 'ind_score' => '1', 'overall_score' => '2' }]

        expect(described_class.from_source(lt4_path, { 'events' => [], 'teamRankings' => rows }).pluck('team_key')).to eq(['Edited'])
      end
    end

    it 'returns an empty list when the LT4 copy has no rankings and no LT2 sibling exists' do
      Dir.mktmpdir do |tmp|
        expect(described_class.from_source(File.join(tmp, 'meeting-lt4.json'), { 'events' => [] })).to eq([])
      end
    end
  end
end
