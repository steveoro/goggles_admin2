# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::Summary do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'counts the scripts per state and returns the oldest pending one' do
    create_sql_script(data_root, 'results.new/262/0012-b-lt4.sql')
    oldest = create_sql_script(data_root, 'results.new/misc/0011-merge_teams-1-2.sql')
    create_sql_script(data_root, 'results.new/misc/0013-x.sql', state: 'held', held_reason: 'operator')
    create_sql_script(data_root, 'results.new/262/0014-c-lt4.sql', state: 'in_doubt')
    create_sql_script(data_root, 'results.sent/262/0005-d-lt4.sql', state: 'sent')
    create_sql_script(data_root, 'results.sent/262/0004-e-lt4.sql')

    summary = described_class.call
    expect(summary.to_h).to include(pending: 2, held: 1, in_doubt: 1, sent_unverified: 1)
    expect(summary.oldest_pending).to eq(oldest)
    expect(summary.waiting).to eq(4)
  end

  it 'is nil without the ops DB' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.call).to be_nil
  end
end
