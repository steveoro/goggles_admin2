# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::DumpInspector do
  let(:fixture) { Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2').to_s }
  let(:dir) { Pathname.new(Dir.mktmpdir) }
  let(:local_version) { '20261027120100' }

  after(:each) { FileUtils.rm_rf(dir) }

  # A bz2 dump in the temp dir built from the fixture's SQL changed by the block.
  def variant(name)
    sql = IO.popen(['bzip2', '-dc', fixture], 'rb', &:read)
    path = dir.join(name).to_s
    IO.popen(['bzip2', '-c'], 'wb', out: path) { |io| io.write(yield(sql)) }
    path
  end

  def inspect_dump(path)
    described_class.call(path, local_schema_version: local_version)
  end

  it 'reads the header, the tables, the schema version, the IQ auto-increment, the dump date and the API URL' do # rubocop:disable RSpec/MultipleExpectations
    result = inspect_dump(fixture)
    expect(result).to be_ok
    expect(result.header_line).to eq('-- /app/db/dump/production.sql')
    expect(result.source_host).to eq('goggles-db')
    expect(result.source_database).to eq('goggles')
    expect(result.tables).to include(*DbRestore::CORE_TABLES, 'sessions')
    expect(result.missing_tables).to be_empty
    expect(result.schema_version).to eq('20261027120100')
    expect(result.iq_next_id).to eq(9124)
    expect(result.taken_at).to eq(Time.zone.parse('2026-11-22 21:30:01'))
    expect(result.taken_at_source).to eq('footer')
    expect(result.api_url).to eq('https://api.example.test')
    expect(result.bytes).to eq(File.size(fixture))
    expect(result.sha256).to eq(Digest::SHA256.file(fixture).hexdigest)
    expect(result.warnings).to be_empty
    expect(result.details).to include('table_count' => result.tables.size, 'errors' => [])
  end

  # mariadb-dump 11.8 (the production container) writes 'INSERT INTO `t` VALUES' alone on its line, then one row per
  # line ('(...),' ... '(...);'): the schema versions and the settings row are on the lines after the INSERT line.
  def one_row_per_line(sql)
    sql.gsub(/^(INSERT INTO `\w+` VALUES) \(/) { "#{Regexp.last_match(1)}\n(" }.gsub('),(', "),\n(")
  end

  it 'reads a dump written one row per line (mariadb-dump 11.8): schema version, API URL and the rest' do
    path = variant('production-0004-multiline.sql.bz2') { |sql| one_row_per_line(sql) }
    expect(IO.popen(['bzip2', '-dc', path], 'rb', &:read)).to include("INSERT INTO `schema_migrations` VALUES\n('20201231000000'),\n")
    result = inspect_dump(path)
    expect(result).to be_ok
    expect(result.schema_version).to eq('20261027120100')
    expect(result.api_url).to eq('https://api.example.test')
    expect(result.iq_next_id).to eq(9124)
    expect(result.taken_at).to eq(Time.zone.parse('2026-11-22 21:30:01'))
  end

  it 'reads the versions of every schema_migrations INSERT (also with a column list), never the rows of other tables' do
    path = variant('production-0005-chunks.sql.bz2') do |sql|
      one_row_per_line(sql)
        .sub("INSERT INTO `schema_migrations` VALUES\n('20201231000000'),\n('20261004130000'),\n('20261027120100');",
             "INSERT INTO `schema_migrations` VALUES ('20201231000000'),('20261004130000');\n" \
             "INSERT INTO `schema_migrations` (`version`) VALUES\n('20261027120100');")
        .sub("INSERT INTO `users` VALUES\n(1),\n(2);", "INSERT INTO `users` VALUES\n(1,'20991231235959'),\n(2,'20991231235959');")
    end
    result = inspect_dump(path)
    expect(result).to be_ok
    expect(result.schema_version).to eq('20261027120100')
  end

  it 'refuses a dump whose header does not name a production dump' do
    path = variant('production-0002-dev.sql.bz2') { |sql| sql.sub('-- /app/db/dump/production.sql', '-- /home/x/db/dump/development.sql') }
    result = inspect_dump(path)
    expect(result).not_to be_ok
    expect(result.errors.pluck('code')).to eq(['not_production'])
  end

  it 'refuses a corrupt file (bzip2 integrity check)' do
    path = dir.join('production-0003-corrupt.sql.bz2').to_s
    File.binwrite(path, File.binread(fixture).byteslice(0, 600))
    result = inspect_dump(path)
    expect(result.errors.pluck('code')).to eq(['integrity'])
    expect(result.tables).to be_empty
  end

  it 'refuses a missing file' do
    expect(inspect_dump(dir.join('nope.sql.bz2').to_s).errors.pluck('code')).to eq(['missing'])
  end

  it 'refuses a schema newer than the local engine (update goggles_db first)' do
    path = variant('production-0004-newer.sql.bz2') { |sql| sql.sub("('20261027120100')", "('20261027120100'),('29991231000000')") }
    result = inspect_dump(path)
    expect(result.errors.pluck('code')).to eq(['schema_newer'])
    expect(I18n.t('db_restore.inspection.errors.schema_newer', detail: 'x')).to include('./update_engine.sh')
  end

  it 'warns about a schema older than the local engine (migrations reported after the restore)' do
    result = described_class.call(fixture, local_schema_version: '20270101000000')
    expect(result).to be_ok
    expect(result.warnings.pluck('code')).to eq(['schema_older'])
  end

  it 'refuses a dump missing core tables' do
    path = variant('production-0005-partial.sql.bz2') { |sql| sql.gsub('CREATE TABLE `badges`', 'CREATE TABLE `other_badges`') }
    result = inspect_dump(path)
    expect(result.errors.pluck('code')).to eq(['missing_tables'])
    expect(result.missing_tables).to eq(['badges'])
  end

  it 'uses the file time without the footer line and lists the Outbox scripts pushed after the dump' do
    path = variant('production-0006-nofooter.sql.bz2') { |sql| sql.sub(/^-- Dump completed on .*\n/, '') }
    File.utime(1.day.ago.to_time, 1.day.ago.to_time, path)
    Ops::SqlScript.create!(seq: 990_001, rel_path: 'results.sent/misc/0990-x.sql', filename: '0990-x.sql', folder: 'misc', kind: 'manual',
                           sha256: 'a' * 64, state: 'applied', pushed_at: 1.hour.ago)
    result = inspect_dump(path)
    expect(result).to be_ok
    expect(result.taken_at_source).to eq('mtime')
    expect(result.warnings.pluck('code')).to eq(%w[no_dump_date scripts_after_dump])
    expect(result.scripts_after_dump).to eq(['0990-x.sql'])
  end
end
