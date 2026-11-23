# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::MeetingCanceller do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:, cancelled: false) }
  let(:calendar) { FactoryBot.create(:calendar, season:, meeting:, cancelled: false) }

  after(:each) { FileUtils.rm_rf(data_root) }

  def canceller(**ids)
    described_class.new(season:, data_root:, **ids)
  end

  def season_files(folder = 'results.new')
    Dir.glob(data_root.join(folder, season.id.to_s, '*').to_s).map { |path| File.basename(path) }
  end

  describe '#preview' do
    it 'returns the facts, the counts, the SQL of both rows and its digest, writing nothing' do
      preview = nil
      ids = { meeting_id: meeting.id, calendar_id: calendar.id }
      writes = primary_db_statements { preview = canceller(**ids).preview }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)
      expect(writes).to be_empty
      expect(preview).to be_ok
      expect(preview.counts).to eq(events: 0, mirs: 0, mrrs: 0)
      expect(preview.statements.size).to eq(2)
      expect(preview.sql).to include('UPDATE `meetings`', 'UPDATE `calendars`', '`cancelled`=TRUE', '`updated_at`=NOW()',
                                     "WHERE `id`=#{meeting.id};", "WHERE `id`=#{calendar.id};")
      expect(preview.digest).to eq(Digest::SHA256.hexdigest(preview.sql))
      expect(season_files).to be_empty
      expect(meeting.reload.cancelled).to be(false)
    end

    it 'refuses a meeting with results, a row of another season and a calendar of another meeting' do
      health_add_mrr(meeting)
      expect(canceller(meeting_id: meeting.id).preview.error).to eq(I18n.t('health.cancellations.errors.has_results'))
      other = FactoryBot.create(:meeting)
      expect(canceller(meeting_id: other.id).preview.error).to eq(I18n.t('health.cancellations.errors.other_season', id: other.id))
      unrelated = FactoryBot.create(:calendar_with_blank_meeting, season:)
      expect(canceller(meeting_id: meeting.id, calendar_id: unrelated.id).preview.error)
        .to eq(I18n.t('health.cancellations.errors.other_meeting', id: unrelated.id))
      expect(described_class.new(season:, data_root:).preview.error).to eq(I18n.t('health.cancellations.errors.no_target'))
    end

    it 'skips the rows already cancelled (nothing to do when both are)' do
      calendar.update!(cancelled: true)
      expect(canceller(meeting_id: meeting.id, calendar_id: calendar.id).preview.statements.size).to eq(1)
      meeting.update_columns(cancelled: true) # rubocop:disable Rails/SkipsModelValidations
      expect(canceller(meeting_id: meeting.id, calendar_id: calendar.id).preview.error)
        .to eq(I18n.t('health.cancellations.errors.nothing_to_do'))
    end
  end

  describe '#call' do
    it 'refuses a digest mismatch, writing nothing' do
      result = canceller(meeting_id: meeting.id).call(expected_digest: 'stale')
      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t('health.cancellations.errors.digest_changed'))
      expect(meeting.reload.cancelled).to be(false)
      expect(season_files).to be_empty
    end

    it 'refuses a meeting that got results after the preview' do
      digest = canceller(meeting_id: meeting.id).preview.digest
      health_add_mir(meeting)
      result = canceller(meeting_id: meeting.id).call(expected_digest: digest)
      expect(result.error).to eq(I18n.t('health.cancellations.errors.has_results'))
      expect(meeting.reload.cancelled).to be(false)
    end

    it 'flags the rows locally and writes one numbered script, matching BOARD_SQL_REGEXP and absent from the unmatched sources' do
      FileUtils.mkdir_p(data_root.join('results.sent', season.id.to_s))
      File.write(data_root.join('results.sent', season.id.to_s, '0041-some-meeting-lt4.sql'), '-- pushed')
      preview = canceller(meeting_id: meeting.id, calendar_id: calendar.id).preview
      result = canceller(meeting_id: meeting.id, calendar_id: calendar.id).call(expected_digest: preview.digest)

      expect(result).to be_success
      expect(File.basename(result.sql_path)).to eq("0042-meeting_cancel-#{meeting.id}.sql")
      expect(season_files).to eq(["0042-meeting_cancel-#{meeting.id}.sql"])
      expect(File.basename(result.sql_path)).to match(SeasonBoard::DiskIndex::BOARD_SQL_REGEXP)
      content = File.read(result.sql_path)
      expect(content).to include('START TRANSACTION;', preview.sql, 'COMMIT;', "meeting_id=#{meeting.id}")
      expect([meeting.reload.cancelled, calendar.reload.cancelled]).to eq([true, true])

      index = SeasonBoard::DiskIndex.new(season_id: season.id, data_dir: data_root)
      expect(index.unmatched).to eq([])
      expect(index.board_sql_paths).to eq([result.sql_path.to_s])
    end

    it 'names a calendar-only script after the calendar' do
      unlinked = FactoryBot.create(:calendar_with_blank_meeting, season:, cancelled: false)
      digest = canceller(calendar_id: unlinked.id).preview.digest
      result = canceller(calendar_id: unlinked.id).call(expected_digest: digest)
      expect(File.basename(result.sql_path)).to eq("0001-calendar_cancel-#{unlinked.id}.sql")
      expect(unlinked.reload.cancelled).to be(true)
    end

    it 'leaves no script and no local change when the local update fails' do
      digest = canceller(meeting_id: meeting.id).preview.digest
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(satisfy { |path| path.to_s.include?('meeting_cancel') }, anything).and_raise(IOError, 'disk full')
      result = canceller(meeting_id: meeting.id).call(expected_digest: digest)
      expect(result.error).to eq('disk full')
      expect(meeting.reload.cancelled).to be(false)
    end
  end
end
