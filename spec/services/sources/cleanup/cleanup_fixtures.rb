# frozen_string_literal: true

require_relative '../../season_board/disk_fixtures'

# Helpers of the clean-up specs (0.10.104): files under a temporary +data_dir+ (season folder '262', see
# SeasonBoardDiskFixtures), aged past Sources::Cleanup::MIN_AGE by default, and a DbIndex stand-in linking FIN ids.
module CleanupFixtures
  include SeasonBoardDiskFixtures

  DOT_ENTRIES = %w[. ..].freeze

  # Sets the mtime of +path+ (default: an hour ago, older than Sources::Cleanup::MIN_AGE). Returns the path.
  def age!(path, time = 1.hour.ago)
    File.utime(time.to_time, time.to_time, path.to_s)
    path
  end

  def old_json(folder, name, hash) = age!(write_json(folder, name, hash))
  def old_file(folder, name, content = '') = age!(write_file(folder, name, content))

  # A DbIndex::CalendarInfo linked to a meeting (or not, with +linked+ false).
  def calendar_info(fin_id, linked: true)
    meeting = if linked
                SeasonBoard::DbIndex::MeetingInfo.new(id: 19_000, description: 'M', code: 'm', header_date: nil, cancelled: false,
                                                      results_acquired: false, manifest: true, mir_count: 0, mrr_count: 0)
              end
    SeasonBoard::DbIndex::CalendarInfo.new(id: 1700, fin_event_id: fin_id, meeting_id: meeting&.id, meeting_code: 'm', meeting_name: 'M',
                                           meeting_place: 'X', scheduled_date: '8', year: '2026', month: 'Nov', cancelled: false,
                                           results_link: nil, meeting:)
  end

  # A DbIndex stand-in whose #calendar_for links the FIN ids of +linked+ (Strings).
  def db_index_linking(*linked)
    index = instance_double(SeasonBoard::DbIndex)
    allow(index).to receive(:calendar_for) { |fin_id| linked.map(&:to_s).include?(fin_id.to_s) ? calendar_info(fin_id.to_s) : nil }
    index
  end

  # Crawler status Hashes (CrawlerClient::Status).
  def crawler_idle = { 'timestamp' => 1.hour.ago.utc.strftime('%Y%m%d-%H%M%S'), 'status' => 'OK, done, idle', 'detail' => 'Done.' }
  def crawler_running = { 'timestamp' => Time.current.utc.strftime('%Y%m%d-%H%M%S'), 'status' => 'OK, processing 1/3', 'detail' => 'x' }

  def sha(path) = Digest::SHA256.file(path.to_s).hexdigest

  # { path relative to +root+ => SHA-256 (a symlink: 'link:<target>') } of every file under +root+ (dot files included).
  def tree(root = data_dir)
    base = Pathname.new(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).each_with_object({}) do |path, memo|
      next if DOT_ENTRIES.include?(File.basename(path)) || (File.directory?(path) && !File.symlink?(path))

      memo[Pathname.new(path).relative_path_from(base).to_s] = File.symlink?(path) ? "link:#{File.readlink(path)}" : sha(path)
    end
  end

  # Asserts that from the +before+ tree to the +after+ one (see #tree) ONLY the +moves+ ({ from => to }, relative paths)
  # happened, each file arriving with the same content, plus the MOVES.txt journals of the run backup folders, which
  # must list every move.
  def expect_only_moves(before, after, moves)
    expected = before.dup
    moves.each { |from, to| expected[to] = expected.delete(from) }
    journals = after.keys.select { |rel| File.basename(rel) == Sources::Cleanup::MOVES_FILE && !before.key?(rel) }
    expect(after.except(*journals)).to eq(expected)
    expect(journal_moves(journals)).to match_array(moves.map { |from, to| "#{from} -> #{to}" })
  end

  # The 'from -> to' parts of the lines of the MOVES.txt files (relative paths).
  def journal_moves(journals)
    journals.flat_map { |rel| File.readlines(File.join(data_dir, rel)).map { |line| line.chomp.split("\t").last } }
  end

  # The run backup folders of the season (relative), oldest first.
  def run_folders(season = SEASON_DIR)
    Dir.glob(File.join(data_dir, 'results.backup', season.to_s, 'cleanup-*')).map { |dir| Pathname.new(dir).relative_path_from(Pathname.new(data_dir)).to_s }
  end
end
