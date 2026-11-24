# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::ScriptBlocks do
  it 'keeps a single-transaction script (or one without COMMIT) as one block' do
    lines = ["\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";", 'SET AUTOCOMMIT = 0;', "START TRANSACTION;\r\n", 'UPDATE x SET y=1;', "\r\nCOMMIT;"]
    expect(described_class.split(lines)).to eq([lines])
    expect(described_class.split(['UPDATE x SET y=1;'])).to eq([['UPDATE x SET y=1;']])
  end

  it 'splits the blocks after each COMMIT, the trailing lines staying with the last block (a partition of the lines)' do
    lines = ['-- header', 'START TRANSACTION;', 'UPDATE a SET b=1;', "\r\nCOMMIT;", '', 'START TRANSACTION;', 'DELETE FROM c;', 'COMMIT;', '-- end']
    blocks = described_class.split(lines)
    expect(blocks).to eq([['-- header', 'START TRANSACTION;', 'UPDATE a SET b=1;', "\r\nCOMMIT;"],
                          ['', 'START TRANSACTION;', 'DELETE FROM c;', 'COMMIT;', '-- end']])
    expect(blocks.flatten).to eq(lines)
  end

  it 'splits the season badge fix step script one block per badge' do
    badge = Merge::Badge.start_transaction_log + ['UPDATE badges SET x=1;'] + Merge::Badge.end_transaction_log
    lines = ['-- Season badge fix', '-- (each badge in its own transaction)', '', *badge, '', *badge]
    expect(described_class.split(lines).size).to eq(2)
  end

  # (every recorded rake parity script, the scripts of the operations behind the tasks, is a single transaction: only
  # the step scripts of 'season.badge_fix' hold several blocks, one per badge)
  it 'finds one block in every script of the recorded rake baselines' do
    names = RakeParity::BASELINE_DIR.glob('*.txt').map { |path| path.basename('.txt').to_s }
    scripts = names.flat_map { |name| RakeParity.baseline_parts(name).last }
    expect(scripts.size).to be >= 19
    scripts.each do |rel_path, sql|
      expect(described_class.split(sql.split("\r\n")).size).to eq(1), rel_path
    end
  end
end
