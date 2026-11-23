# frozen_string_literal: true

require 'rails_helper'

# The spec guard of the Outbox: in the test environment nothing may write, move or register the real scripts.
RSpec.describe Outbox do
  let(:real_root) { Rails.root.join('crawler/data') }

  it 'refuses a write under the real crawler data folder' do
    expect do
      Outbox::Writer.write!(kind: 'merge', name: 'merge_teams-1-2', sql: 'SELECT 1;', folder: 'misc', data_root: real_root)
    end.to raise_error(Outbox::Error, /real crawler data folder/)
    expect(real_root.join('results.new/misc').glob('*-merge_teams-1-2.sql')).to be_empty
  end

  it 'refuses a reconcile of the real crawler data folder (a dry run is allowed: read only)' do
    expect { Outbox::Reconciler.call(data_root: real_root) }.to raise_error(Outbox::Error)
    expect(Ops::SqlScript.count).to eq(0)
  end

  it 'lets a temporary data root through' do
    dir = Dir.mktmpdir
    expect { described_class.guard_test_path!(File.join(dir, 'results.new')) }.not_to raise_error
  ensure
    FileUtils.rm_rf(dir)
  end
end
