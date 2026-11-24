# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::RemoteStatus do
  # The outcome encoding of the import queue rows of the SQL batches (goggles_main / goggles_api 0.10.82)
  {
    'queued' => [{ 'id' => 1, 'batch_sql' => true, 'done' => false, 'process_runs' => 0, 'error_messages' => nil }, :queued],
    'running' => [{ 'id' => 1, 'done' => false, 'process_runs' => 1, 'error_messages' => nil }, :running],
    'applied' => [{ 'id' => 1, 'done' => true, 'process_runs' => 1, 'error_messages' => nil }, :applied],
    'applied (done as String)' => [{ 'id' => 1, 'done' => 'true', 'process_runs' => 1 }, :applied],
    'failed' => [{ 'id' => 1, 'done' => false, 'process_runs' => 1, 'error_messages' => 'ERROR 1062 (23000) at line 412' }, :failed],
    'failed, interrupted' => [{ 'id' => 1, 'done' => false, 'process_runs' => 1, 'error_messages' => 'interrupted: outcome unknown' }, :failed],
    'queued again after a retry (empty error)' => [{ 'id' => 1, 'done' => false, 'process_runs' => 0, 'error_messages' => '' }, :queued],
    'gone (null body)' => [nil, :gone],
    'gone (empty Hash)' => [{}, :gone]
  }.each do |label, (json, outcome)|
    it "maps #{label} to #{outcome.inspect}" do
      expect(described_class.map(json)).to eq(outcome)
    end
  end

  it 'returns the server error text of a failed row only' do
    expect(described_class.error_for({ 'error_messages' => " ERROR 1062 \n" })).to eq('ERROR 1062')
    expect(described_class.error_for({ 'error_messages' => '' })).to be_nil
    expect(described_class.error_for(nil)).to be_nil
  end
end
