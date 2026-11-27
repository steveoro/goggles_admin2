# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Verification::ResultDuplicateChecker do
  subject(:checker) { described_class.new }

  let(:existing) { FactoryBot.create(:meeting_individual_result, minutes: 0, seconds: 30, hundredths: 0) }
  let(:program) { existing.meeting_program }
  let(:event) { program.meeting_event }
  let(:meeting_id) { event.meeting_session.meeting_id }
  let(:season_id) { program.category_type.season_id }
  let(:timing) { { minutes: 0, seconds: 30, hundredths: 0 } }

  def program_key_for(category_code)
    [event.meeting_session.session_order, event.event_type.code, category_code, program.gender_type.code].join('-')
  end

  def check(category_code:, check_timing: timing)
    checker.check_individual(
      swimmer_id: existing.swimmer_id,
      meeting_program_id: nil,
      meeting_id:,
      meeting_program_key: program_key_for(category_code),
      timing: check_timing,
      team_id: existing.team_id,
      season_id:
    )
  end

  it 'classifies exact timing in another category as a category correction' do
    result = check(category_code: 'M99')

    expect(result[:category_corrections].pluck('id')).to include(existing.id)
    expect(result[:perfect_matches]).to be_empty
    expect(result[:partial_matches]).to be_empty
  end

  it 'classifies changed timing in another category as a timing-change category correction' do
    result = check(category_code: 'M99', check_timing: { minutes: 0, seconds: 31, hundredths: 0 })

    expect(result[:category_timing_corrections].pluck('id')).to include(existing.id)
    expect(result[:category_corrections]).to be_empty
  end

  it 'keeps exact same-category matches in the perfect tier' do
    result = check(category_code: program.category_type.code)

    expect(result[:perfect_matches].pluck('id')).to include(existing.id)
    expect(result[:category_corrections]).to be_empty
  end
end
