# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::SeasonProgressComponent, type: :component do
  let(:season) { instance_double(GogglesDb::Season, description: 'MASTER FIN 2026/2027') }

  def summary(counts)
    SeasonBoard::Snapshot::Summary.from_payload({ 'season_id' => 262, 'state_counts' => counts, 'rows' => [] },
                                                stored: true, taken_at: Time.current)
  end

  it 'renders one segment and one chip per state with rows, in pipeline order, each opening the filtered board' do
    rendered = render_inline(described_class.new(summary: summary('not_linked' => 40, 'sql_pending' => 3, 'in_review' => 0), season:))
    expect(rendered.css('[data-state-segment]').pluck('data-state-segment')).to eq(%w[sql_pending not_linked])
    chips = rendered.css('[data-state-chip]')
    expect(chips.pluck('href')).to eq(['/season_board?state=sql_pending', '/season_board?state=not_linked'])
    expect(chips.first.text).to eq(I18n.t('dashboard.season_progress.segment', state: I18n.t('season_board.states.sql_pending'), count: 3))
    expect(rendered.text).to include('MASTER FIN 2026/2027', I18n.t('dashboard.season_progress.total', count: 43))
  end

  it 'says so without a season or a summary' do
    expect(render_inline(described_class.new(summary: nil, season: nil)).text).to include(I18n.t('dashboard.season_progress.no_season'))
    expect(render_inline(described_class.new(summary: nil, season:)).text).to include(I18n.t('dashboard.season_progress.no_data'))
  end
end
