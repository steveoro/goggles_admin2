# frozen_string_literal: true

# = StatsHelper
#
# Helpers used by the API usage statistics dashboard.
module StatsHelper
  # Builds a matrix of daily user-agent counts for the stats summary table.
  def daily_agents_matrix(rows, agents: [])
    daily_rows = Array(rows)
    {
      days: daily_rows.filter_map { |row| daily_agent_value(row, 'day')&.to_s }.uniq.sort,
      agents: ordered_daily_agents(daily_rows, agents),
      counts: daily_agent_counts(daily_rows)
    }
  end

  private

  def daily_agent_value(row, key)
    row[key] || row[key.to_sym]
  end

  def ordered_daily_agents(rows, agents)
    daily_agents = rows.filter_map { |row| daily_agent_value(row, 'user_agent')&.to_s }.uniq
    top_agents = Array(agents).filter_map do |agent|
      value = agent.is_a?(Hash) ? daily_agent_value(agent, 'user_agent') : agent
      value&.to_s
    end.uniq

    top_agents + daily_agents.reject { |agent| top_agents.include?(agent) }
  end

  def daily_agent_counts(rows)
    rows.each_with_object({}) do |row, result|
      agent = daily_agent_value(row, 'user_agent')&.to_s
      day = daily_agent_value(row, 'day')&.to_s
      next if agent.blank? || day.blank?

      key = [agent, day]
      result[key] = result.fetch(key, 0) + daily_agent_value(row, 'total_count').to_i
    end
  end
end
