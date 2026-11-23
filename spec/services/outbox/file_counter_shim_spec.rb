# frozen_string_literal: true

require 'rails_helper'

# FileCounter (kept for compatibility) is a shim over Outbox::Sequence: the counter is global and its data root is
# the path before 'results.new' of the given folder.
RSpec.describe FileCounter do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:counter) { Class.new { include FileCounter }.new }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'returns the global max of the data root of the folder, even for an empty season folder' do
    write_sql_file(data_root, 'results.sent/misc/0476-merge_teams-1-2.sql')
    write_sql_file(data_root, 'results.new/262/0012-a-lt4.sql')
    result = counter.send(:compute_file_counter, data_root.join('results.new', '999'), data_root.join('results.sent', '999'))
    expect(result).to eq(476)
  end
end
