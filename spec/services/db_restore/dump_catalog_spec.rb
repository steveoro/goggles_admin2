# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::DumpCatalog do
  let(:main_dir) { Pathname.new(Dir.mktmpdir) }
  let(:admin_dir) { Pathname.new(Dir.mktmpdir) }
  let(:catalog) { described_class.new(dirs: [main_dir.to_s, admin_dir.to_s]) }

  after(:each) do
    FileUtils.rm_rf([main_dir, admin_dir])
    Ops::Database.reset_state!
  end

  def dump(dir, name, age: 0)
    path = dir.join(name)
    File.binwrite(path, 'x' * 10)
    File.utime(age.days.ago.to_time, age.days.ago.to_time, path)
    path.to_s
  end

  it 'lists only the production dumps of every folder, newest first' do
    old = dump(main_dir, 'production-0423-backup.sql.bz2', age: 3)
    newest = dump(admin_dir, 'production-0430-backup.sql.bz2', age: 1)
    dump(main_dir, 'development-0431-x.sql.bz2')
    dump(main_dir, 'production-0432-x.sql')
    expect(catalog.entries.map(&:path)).to eq([newest, old])
    entry = catalog.entries.first
    expect(entry).to have_attributes(basename: 'production-0430-backup.sql.bz2', bytes: 10, number: 430, rebuild_name: 'production-0430-backup')
  end

  it 'finds only listed dumps' do
    path = dump(main_dir, 'production-0423-backup.sql.bz2')
    other = dump(main_dir, 'development-0424-x.sql.bz2')
    expect(catalog.find(path).path).to eq(path)
    expect(catalog.find(other)).to be_nil
    expect(catalog.find('/etc/passwd')).to be_nil
    expect(catalog.find(nil)).to be_nil
  end

  it 'names the next safety snapshot after the highest dump number, in the first folder' do
    dump(main_dir, 'production-0430-backup.sql.bz2')
    dump(admin_dir, 'development-0431_struct.sql.bz2')
    expect(catalog.next_number).to eq(432)
    expect(catalog.next_snapshot_path).to eq(main_dir.join('development-0432-pre-restore.sql.bz2').to_s)
  end

  it 'uses the stored folders, else the defaults (goggles_main/db/dump, db/dump)' do
    expect(described_class.new.dirs).to eq(described_class.default_dirs)
    expect(described_class.default_dirs.last).to eq(Rails.root.join('db/dump').to_s)
    described_class.store_dirs!("#{main_dir}\n\n #{admin_dir} \n")
    expect(described_class.new.dirs).to eq([main_dir.to_s, admin_dir.to_s])
    described_class.store_dirs!('')
    expect(described_class.new.dirs).to eq(described_class.default_dirs)
  end
end
