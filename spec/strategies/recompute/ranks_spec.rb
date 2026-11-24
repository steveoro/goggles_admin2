# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Recompute::Ranks do
  let(:meeting) { FactoryBot.create(:meeting) }
  let(:program) { health_individual_program(meeting) }

  def mir(seconds, rank)
    FactoryBot.create(:meeting_individual_result, meeting_program: program, minutes: 0, seconds:, hundredths: 0, rank:)
  end

  it 'collects one UPDATE per row whose rank changes (timed rows first, then the zero timings), in one transaction' do
    fast = mir(30, 3)
    slow = mir(40, 1)
    zero = mir(0, 2)
    ok = mir(35, 2)
    ranker = described_class.new(meeting: GogglesDb::Meeting.find(meeting.id)).call
    updates = ranker.sql_log.grep(/\AUPDATE/)
    expect(updates).to eq([
                            "UPDATE meeting_individual_results SET updated_at=NOW(), rank=1 WHERE id = #{fast.id}; -- MPrg: #{program.id}, #{fast.to_timing}",
                            "UPDATE meeting_individual_results SET updated_at=NOW(), rank=3 WHERE id = #{slow.id}; -- MPrg: #{program.id}, #{slow.to_timing}",
                            "UPDATE meeting_individual_results SET updated_at=NOW(), rank=4 WHERE id = #{zero.id}; -- MPrg: #{program.id}, #{zero.to_timing}"
                          ])
    expect(updates.join).not_to include("id = #{ok.id};")
    expect(ranker.sql_log.first(3)).to eq(Merge::Badge.start_transaction_log)
    expect(ranker.sql_log.last).to eq(Merge::Badge.end_transaction_log.last)
    expect(ranker.updates_by_meeting).to eq(meeting.id => 3)
    expect(ranker.season).to eq(meeting.season)
  end

  it 'yields the progress events instead of printing' do
    mir(30, 1)
    events = []
    expect { described_class.new(meeting: GogglesDb::Meeting.find(meeting.id)).call { |event, _payload| events << event } }.not_to output.to_stdout
    expect(events).to eq(%i[meeting program meeting_done])
  end

  it 'prefers the season to the meeting and needs one of them' do
    expect(described_class.new(season: meeting.season, meeting:).meeting).to be_nil
    expect { described_class.new }.to raise_error(ArgumentError)
  end
end
