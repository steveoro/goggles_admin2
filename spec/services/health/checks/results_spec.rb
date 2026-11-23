# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Checks::Results do
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:) }
  let(:findings) { described_class.new(season:, entry: health_entry(season, status: :closed)).call }

  def by_check(key)
    findings.select { |finding| finding.check_key == key }
  end

  it 'reports duplicate MIRs per meeting with the rake command and a stable identity' do
    mir = health_add_mir(meeting)
    FactoryBot.create(:meeting_individual_result, meeting_program: mir.meeting_program, badge: mir.badge,
                                                  minutes: mir.minutes, seconds: mir.seconds, hundredths: mir.hundredths)
    list = by_check('results.duplicates')
    expect(list.map(&:identity)).to eq(["meeting:#{meeting.id}"])
    expect(list.first.payload['counts']).to include('mirs' => 1)
    expect(list.first.payload['duplicate_mirs'].first).to include('swimmer_id' => mir.swimmer_id, 'timing_match' => true)
    expect(list.first.payload['null_swimmers_first']).to be(false)
    expect(Health::Registry.fetch('results.duplicates').rake_command(list.first.payload['rake']))
      .to eq("bin/rails check:dup_mir_swimmers meeting_id=#{meeting.id} autofix=1")
    # (more than one MIR for the same badge and program)
    expect(by_check('results.dup_mir_per_badge').first.payload['badge_ids']).to eq([mir.badge_id])
  end

  context 'with a NULL-swimmer relay swimmer pair' do
    let(:mrr) { health_add_mrr(meeting) }

    before(:each) do
      2.times do
        mrs = FactoryBot.create(:meeting_relay_swimmer, meeting_relay_result: mrr)
        mrs.update_columns(swimmer_id: nil) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    it 'reports the null swimmers, and the duplicate MRS pair telling to fix the null swimmers first' do
      null = by_check('results.null_swimmers')
      expect(null.map(&:subject_id)).to eq([meeting.id])
      expect(null.first.payload.dig('report', 'mrss', 'fixable')).to eq(2)
      expect(null.first.title_args).to include('mrss' => 2, 'mirs' => 0)

      duplicates = by_check('results.duplicates')
      expect(duplicates.first.payload['counts']).to include('mrss' => 1)
      expect(duplicates.first.payload['null_swimmers_first']).to be(true)
    end

    it 'pins the report-versus-delete mismatch: the generated MRS deletion joins on swimmer_id (never NULL)' do
      cleaner = Merge::DuplicateResultCleaner.new(meeting:, autofix: true)
      expect(cleaner.find_duplicate_mrss(meeting.id)).to eq([[nil, mrr.id]])
      sql = cleaner.prepare.join("\n")
      expect(sql).to include('mrs1.swimmer_id = mrs2.swimmer_id')
    end
  end
end
