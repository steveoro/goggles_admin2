# frozen_string_literal: true

require 'rails_helper'

# (phase 09: ported from the former data_fix/commit_phase6_report.html.haml spec; the statistics table now lives in
# the persistent commit report, data_fix/commit_reports/_stats)
RSpec.describe 'data_fix/commit_reports/_stats.html.haml' do
  let(:base_stats) do
    {
      meetings_created: 1, team_scores_created: 4, team_scores_updated: 1, team_scores_skipped: 0,
      team_links_auto_fixed: 0, affiliation_links_auto_fixed: 0, errors: []
    }
  end

  def render_report(stats)
    render(partial: 'data_fix/commit_reports/stats', locals: { stats: })
  end

  it 'lists the committed team scores in the statistics table' do
    render_report(base_stats)

    expect(rendered).to match(%r{<td>Team Scores</td>\s*<td class=['"]text-center['"]>4</td>\s*<td class=['"]text-center['"]>1</td>})
    expect(rendered).not_to include(I18n.t('data_import.data_fix.team_scores.skipped'))
  end

  it 'reports the skipped team scores in the auto-fix summary' do
    render_report(base_stats.merge(team_scores_skipped: 2))

    expect(rendered).to include(I18n.t('data_import.data_fix.team_scores.skipped'))
    expect(rendered).to match(%r{<strong>2</strong>\s*#{Regexp.escape(I18n.t('data_import.data_fix.team_scores.skipped'))}})
  end
end
