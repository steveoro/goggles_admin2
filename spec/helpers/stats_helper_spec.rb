# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StatsHelper do
  include described_class

  describe '#daily_agents_matrix' do
    it 'orders days and aggregates counts by agent' do
      rows = [
        { 'user_agent' => 'Agent B', 'day' => '2026-09-13', 'total_count' => 3 },
        { 'user_agent' => 'Agent A', 'day' => '2026-09-12', 'total_count' => 2 },
        { 'user_agent' => 'Agent B', 'day' => '2026-09-12', 'total_count' => 1 }
      ]

      expect(daily_agents_matrix(rows)).to eq(
        days: %w[2026-09-12 2026-09-13],
        agents: ['Agent B', 'Agent A'],
        counts: {
          ['Agent B', '2026-09-13'] => 3,
          ['Agent A', '2026-09-12'] => 2,
          ['Agent B', '2026-09-12'] => 1
        }
      )
    end

    it 'prefers the top-agent order when provided' do
      rows = [
        { 'user_agent' => 'Agent A', 'day' => '2026-09-12', 'total_count' => 2 },
        { 'user_agent' => 'Agent B', 'day' => '2026-09-12', 'total_count' => 1 }
      ]

      expect(daily_agents_matrix(rows, agents: ['Agent B', 'Agent A']).fetch(:agents))
        .to eq(['Agent B', 'Agent A'])
    end
  end
end
