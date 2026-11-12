# frozen_string_literal: true

require 'rails_helper'
require 'base64'
require 'tmpdir'

RSpec.describe SeasonBoard::Backfill do
  # == Helpers ===============================================================

  def fin_page
    'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html'
  end

  def results_url(fin_id, slug = 'some-meeting')
    "#{fin_page}#/risultati/#{fin_id}:#{slug}.html"
  end

  def manifest_url(fin_id)
    encoded = Base64.strict_encode64("/var/www/fin_files/eventi/0000#{fin_id}.pdf")
    "https://www.federnuoto.it/component/solrconnect/download.html?file=#{encoded}"
  end

  def season_dir(kind)
    dir = File.join(data_root, kind, season.id.to_s)
    FileUtils.mkdir_p(dir)
    dir
  end

  def write_json(kind, file_name, hash)
    File.write(File.join(season_dir(kind), file_name), JSON.pretty_generate(hash))
  end

  def write_sql(kind, file_name, *statements)
    body = ['-- test batch', 'SET AUTOCOMMIT = 0;', 'START TRANSACTION;', *statements, 'COMMIT;'].join("\r\n")
    File.write(File.join(season_dir(kind), file_name), body)
  end

  # Statement shapes copied from real commit files (SqlMaker output).
  def meeting_insert(meeting_id)
    "INSERT INTO `meetings` (`id`, `description`, `manifest`, `season_id`, `created_at`, `updated_at`, `code`)\r\n  " \
      "VALUES (#{meeting_id}, 'A meeting, with commas; and semicolons', TRUE, #{season.id}, NOW(), NOW(), 'acode');"
  end

  def meeting_update(meeting_id)
    "UPDATE `meetings`\r\n  SET `notes`='meetingURL: https://x.y/#/a;b', `updated_at`=NOW()\r\n  WHERE `id`=#{meeting_id};"
  end

  def calendar_insert(calendar_id, meeting_id)
    "INSERT INTO `calendars` (`id`, `scheduled_date`, `meeting_name`, `meeting_place`, `season_id`, `meeting_id`)\r\n  " \
      "VALUES (#{calendar_id}, '2026-10-24', 'Name, with comma', 'O''Hara (NA)', #{season.id}, #{meeting_id});"
  end

  def calendar_update(calendar_id)
    "UPDATE `calendars`\r\n  SET `updated_at`=NOW()\r\n  WHERE `id`=#{calendar_id};"
  end

  def create_calendar(meeting, attrs = {})
    FactoryBot.create(:calendar, meeting:, season:, **attrs)
  end

  # Moves the session of a random MIR (or MRR) under the given meeting.
  def add_result_to(meeting, factory = :meeting_individual_result)
    result = FactoryBot.create(factory)
    result.meeting_program.meeting_event.meeting_session.update!(meeting_id: meeting.id)
    result
  end

  let(:data_root) { Dir.mktmpdir }
  let(:season) { FactoryBot.create(:season, season_type: GogglesDb::SeasonType.mas_fin) }
  let(:snapshot_rows) { [] }

  after(:each) { FileUtils.rm_rf(data_root) }

  def backfill(simulate: true)
    described_class.new(season:, simulate:, data_root:, snapshot_rows:).call
  end

  def resolved_for(subject, calendar)
    subject.resolved.find { |row| row[:calendar_id] == calendar.id }
  end

  # == Resolution paths ======================================================

  describe 'resolution' do
    subject(:result) { backfill }

    let(:meeting_a) { FactoryBot.create(:meeting, season:) }
    let(:meeting_b) { FactoryBot.create(:meeting, season:) }
    let(:meeting_c) { FactoryBot.create(:meeting, season:) }
    let(:meeting_d) { FactoryBot.create(:meeting, season:) }
    let(:meeting_e) { FactoryBot.create(:meeting, season:) }
    let!(:calendar_a) { create_calendar(meeting_a) }
    let!(:calendar_b) { create_calendar(meeting_b, results_link: 'https://nuoto.ficr.it/#/NUO/tempi/x') }
    let!(:calendar_c) { create_calendar(meeting_c) }
    let!(:calendar_d) { create_calendar(meeting_d) }
    let!(:calendar_e) { create_calendar(meeting_e) }

    let(:snapshot_rows) do
      [
        { 'year' => '2026', 'date' => '08/11', 'name' => 'Memorial Lalla Cecchi', 'place' => 'Trieste',
          'url' => results_url(150_093) },
        { 'year' => '2026', 'date' => '15/11', 'name' => '23° Trofeo De Akker', 'place' => 'Bologna',
          'url' => results_url(150_100) },
        { 'year' => '2027', 'date' => '07/02', 'name' => 'No link yet', 'place' => 'Cosenza', 'url' => '' }
      ]
    end

    before(:each) do
      # (a) LT2 file with both URLs + (b) first-pass commit with a meetings INSERT:
      write_json('results.done', '2026-10-24-Alpha.json',
                 'layoutType' => 2, 'meetingURL' => results_url(150_091), 'manifestURL' => manifest_url(150_091))
      write_json('results.done', '2026-10-24-Alpha-lt4.json', 'layoutType' => 4, '_meta' => { 'meeting_only' => true })
      write_sql('results.sent', '0001-2026-10-24-Alpha-lt4.sql',
                meeting_insert(meeting_a.id), calendar_insert(calendar_a.id, meeting_a.id))

      # (a) LT4 file carrying only the manifest URL + (b) second-pass commit (UPDATEs only), in results.done:
      write_json('results.new', '2026-10-25-Beta-lt4.json', 'layoutType' => 4, 'manifestURL' => manifest_url(150_092))
      write_sql('results.done', '0002-2026-10-25-Beta-lt4.sql',
                meeting_update(meeting_b.id), calendar_update(calendar_b.id))

      # (b) fallback: no meetings statement, meeting_id taken from the calendars INSERT (in results.new):
      write_json('results.done', '2026-11-01-Gamma.json', 'layoutType' => 2, 'meetingURL' => results_url(150_098))
      write_sql('results.new', '0003-2026-11-01-Gamma-lt4.sql', calendar_insert(calendar_c.id, meeting_c.id))

      # (c) manifest-only source without URLs, base predicted from the watcher snapshot:
      write_json('results.done', '2026-11-08-Memorial_Lalla_Cecchi-lt4.json', 'layoutType' => 4)
      write_sql('results.sent', '0004-2026-11-08-Memorial_Lalla_Cecchi-lt4.sql', meeting_insert(meeting_d.id))

      # Unresolvable: file name not predictable from the snapshot row, no URL in the file:
      write_json('results.done', '20261115-DeAkker_2027B15B-lt4.json', 'layoutType' => 4)
      write_sql('results.sent', '0005-20261115-DeAkker_2027B15B-lt4.sql', meeting_insert(meeting_e.id))
    end

    it 'resolves the FIN id from an LT2 file and the meeting from a meetings INSERT' do
      row = resolved_for(result, calendar_a)
      expect(row).to include(meeting_id: meeting_a.id, fin_event_id: '150091', fin_source: :source_file,
                             meeting_source: :meetings_sql)
    end

    it 'resolves the FIN id from an LT4 file and the meeting from a second-pass meetings UPDATE' do
      row = resolved_for(result, calendar_b)
      expect(row).to include(meeting_id: meeting_b.id, fin_event_id: '150092', fin_source: :source_file,
                             meeting_source: :meetings_sql)
    end

    it 'falls back to the meeting_id of the calendars statement' do
      row = resolved_for(result, calendar_c)
      expect(row).to include(meeting_id: meeting_c.id, fin_event_id: '150098', meeting_source: :calendars_sql)
    end

    it 'resolves the FIN id through the snapshot row predicting the file name' do
      row = resolved_for(result, calendar_d)
      expect(row).to include(meeting_id: meeting_d.id, fin_event_id: '150093', fin_source: :snapshot)
    end

    it 'drops a predicted file name shared by two snapshot rows (the calendar stays unresolved)' do
      snapshot_rows << { 'year' => '2026', 'date' => '08/11', 'name' => 'Memorial Lalla Cecchi', 'place' => 'Trieste',
                         'url' => results_url(150_094) }
      expect(resolved_for(result, calendar_d)).to be_nil
      expect(result.unresolved.pluck(:calendar_id)).to include(calendar_d.id)
    end

    it 'reports the calendar rows left unresolved, with same-date snapshot candidates' do
      calendar_e.update!(scheduled_date: '2026-11-15')
      expect(result.unresolved.pluck(:calendar_id)).to eq([calendar_e.id])
      expect(result.unresolved.first[:candidates]).to contain_exactly(hash_including(fin_event_id: '150100'))
    end

    it 'generates an UPDATE setting results_code (and the links) for each resolved row' do
      sql = result.statements.join("\n")
      expect(sql).to include("`results_code`='150091'").and include("WHERE `id`=#{calendar_a.id};")
      expect(sql).to include("`results_link`=#{ActiveRecord::Base.connection.quote(results_url(150_091))}")
      expect(sql).to include("`manifest_link`=#{ActiveRecord::Base.connection.quote(manifest_url(150_091))}")
      expect(sql).not_to include("WHERE `id`=#{calendar_e.id};")
    end

    it 'keeps a non-FIN results_link when no FIN results URL is known' do
      calendar_b.update!(results_code: '150092', manifest_link: manifest_url(150_092))
      expect(backfill.statements.join("\n")).not_to include("WHERE `id`=#{calendar_b.id};")
    end

    it 'replaces a non-FIN results_link with a known FIN one' do
      write_json('results.done', '2026-10-25-Beta.json', 'layoutType' => 2, 'meetingURL' => results_url(150_092))
      sql = backfill.statements.join("\n")
      expect(sql).to include("`results_link`=#{ActiveRecord::Base.connection.quote(results_url(150_092))}")
    end

    it 'takes the results URL from the snapshot row with the same FIN id when the file lacks it' do
      snapshot_rows << { 'year' => '2026', 'date' => '25/10', 'name' => 'Whatever', 'place' => 'X',
                         'url' => results_url(150_092, 'beta') }
      sql = backfill.statements.join("\n")
      expect(sql).to include("`results_link`=#{ActiveRecord::Base.connection.quote(results_url(150_092, 'beta'))}")
    end

    it 'skips the rows already up to date (idempotency)' do
      calendar_a.update!(results_code: '150091', results_link: results_url(150_091),
                         manifest_link: manifest_url(150_091))
      expect(backfill.statements.join("\n")).not_to include("WHERE `id`=#{calendar_a.id};")
      expect(resolved_for(backfill, calendar_a)).to include(fin_event_id: '150091', changes: {})
    end

    it 'never replaces an existing FIN results_link' do
      existing = results_url(150_091, 'other-slug')
      calendar_a.update!(results_link: existing)
      statement = backfill.statements.find { |sql| sql.include?("WHERE `id`=#{calendar_a.id};") }
      expect(statement).to include('`results_code`').and include('`manifest_link`')
      expect(statement).not_to include('`results_link`')
    end
  end

  # == Modes & idempotency ===================================================

  describe 'modes' do
    let(:meeting) { FactoryBot.create(:meeting, season:) }
    let!(:calendar) { create_calendar(meeting) }

    before(:each) do
      write_json('results.done', '2026-10-24-Alpha.json', 'layoutType' => 2, 'meetingURL' => results_url(150_091))
      write_sql('results.sent', '0007-2026-10-24-Alpha-lt4.sql', meeting_insert(meeting.id))
    end

    context 'when simulating (default)' do
      it 'changes nothing and writes no file' do
        result = described_class.new(season:, data_root:, snapshot_rows:).call
        expect(result.statements).not_to be_empty
        expect(result.file_path).to be_nil
        expect(calendar.reload.results_code).to be_nil
        expect(Dir.glob(File.join(data_root, 'results.new', '**', '*backfill*'))).to be_empty
      end

      it 'still returns the wrapped single-transaction script' do
        sql = backfill.sql_log.join("\n")
        expect(sql).to include('START TRANSACTION;').and include('COMMIT;')
      end
    end

    context 'when applying (simulate: false)' do
      subject(:result) { backfill(simulate: false) }

      it 'updates the local rows' do
        result
        expect(calendar.reload.results_code).to eq('150091')
        expect(calendar.results_link).to eq(results_url(150_091))
      end

      it 'writes a numbered SQL script in results.new/<season>, following the results.sent counter' do
        expect(result.file_path.to_s).to eq(
          File.join(data_root, 'results.new', season.id.to_s, "0008-season_board_backfill-#{season.id}.sql")
        )
        content = File.read(result.file_path)
        expect(content).to include('START TRANSACTION;').and include("`results_code`='150091'").and include('COMMIT;')
      end

      it 'is idempotent: a second run has nothing to do and writes no file' do
        result
        second = backfill(simulate: false)
        expect(second.statements).to be_empty
        expect(second.file_path).to be_nil
        expect(Dir.glob(File.join(data_root, 'results.new', season.id.to_s, '*.sql')).size).to eq(1)
      end
    end
  end

  # == results_acquired ======================================================

  describe 'results_acquired' do
    let(:with_mir) { FactoryBot.create(:meeting, season:) }
    let(:with_mrr) { FactoryBot.create(:meeting, season:) }
    let(:empty_meeting) { FactoryBot.create(:meeting, season:) }
    let(:already_set) { FactoryBot.create(:meeting, season:) }

    before(:each) do
      [with_mir, with_mrr, empty_meeting, already_set].each { |m| m.update!(results_acquired: false) }
      already_set.update!(results_acquired: true)
      add_result_to(with_mir)
      add_result_to(with_mrr, :meeting_relay_result)
      add_result_to(already_set)
    end

    it 'flags only the season meetings having results and the flag still false' do
      sql = backfill.statements.join("\n")
      expect(sql).to include("WHERE `id`=#{with_mir.id};").and include("WHERE `id`=#{with_mrr.id};")
      expect(sql).not_to include("WHERE `id`=#{empty_meeting.id};")
      expect(sql).not_to include("WHERE `id`=#{already_set.id};")
      expect(sql).to include('`results_acquired`=TRUE').or include('`results_acquired`=1')
    end

    it 'sets the flag locally when applying' do
      backfill(simulate: false)
      expect(with_mir.reload.results_acquired).to be(true)
      expect(with_mrr.reload.results_acquired).to be(true)
      expect(empty_meeting.reload.results_acquired).to be(false)
    end
  end

  describe '#report' do
    it 'returns printable lines with the counts' do
      lines = backfill.report
      expect(lines).to be_an(Array)
      expect(lines.join("\n")).to include('Resolved').and include('Unresolved')
    end
  end
end
