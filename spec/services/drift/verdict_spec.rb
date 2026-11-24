# frozen_string_literal: true

require 'rails_helper'

# Pure function: no DB, no network.
RSpec.describe Drift::Verdict do
  let(:schema) { '20261027120100' }
  let(:applied_at) { Time.zone.parse('2026-11-22 10:00:00') }
  let(:same) { { 'laps' => row(10, 100), 'meetings' => row(5, 50) } }

  def side(tables, schema_version: schema)
    { 'schema_version' => schema_version, 'tables' => tables }
  end

  def remote(tables, status: 'ok', schema_version: schema, batch_failed: 0)
    payload = status == 'ok' ? side(tables, schema_version:).merge('import_queue' => { 'batch_failed' => batch_failed }) : {}
    Drift::Fingerprint::Remote.new(status:, payload:, error: status == 'ok' ? nil : 'boom')
  end

  def facts(pending: 0, sent: 0, failed: [], missing_remote: 0, last_applied_at: nil)
    Drift::Verdict::OutboxFacts.new(pending:, sent:, failed:, missing_remote:, last_applied_at:)
  end

  def row(count, max_id, max_updated_at = nil)
    { 'count' => count, 'max_id' => max_id, 'max_updated_at' => max_updated_at }.compact
  end

  # (remote_options: status:, schema_version:, batch_failed:)
  def verdict(local_tables, remote_tables, outbox: facts, remote_writes: 0, **remote_options)
    described_class.call(local: side(local_tables), remote: remote(remote_tables, **remote_options), outbox:, remote_writes:)
  end

  # Table-driven: [label, local tables, remote tables, Outbox facts, [expected verdict, expected codes]]
  [
    ['equal counts and max ids', { 'laps' => [10, 100] }, { 'laps' => [10, 100] }, {}, ['green', %w[in_sync]]],
    ['local ahead with scripts pending', { 'laps' => [12, 102] }, { 'laps' => [10, 100] }, { pending: 2 }, ['green', %w[local_ahead]]],
    ['local ahead with scripts queued on the server', { 'laps' => [12, 102] }, { 'laps' => [10, 100] }, { sent: 1 }, ['green', %w[local_ahead]]],
    ['local ahead with nothing to push', { 'laps' => [12, 102] }, { 'laps' => [10, 100] }, {}, ['amber', %w[local_ahead_unpushed]]],
    ['remote laps max id above the local one (users added laps)', { 'laps' => [10, 100] }, { 'laps' => [11, 101] }, { pending: 1 },
     ['red', %w[id_collision]]],
    ['remote users max id above the local one (no commit inserts users)', { 'users' => [10, 100] }, { 'users' => [12, 102] }, {},
     ['amber', %w[remote_ahead]]],
    ['same max id, different count', { 'meetings' => [10, 100] }, { 'meetings' => [9, 100] }, {}, ['amber', %w[count_differs]]],
    ['a table missing on one side', { 'laps' => [10, 100] }, {}, {}, ['amber', %w[table_unknown]]]
  ].each do |label, mine, theirs, outbox, (expected, codes)|
    it "is #{expected} for #{label}" do
      local_tables = mine.transform_values { |count, max_id| row(count, max_id) }
      remote_tables = theirs.transform_values { |count, max_id| row(count, max_id) }
      result = verdict(local_tables, remote_tables, outbox: facts(**outbox))
      expect(result.verdict).to eq(expected)
      expect(result.codes).to eq(codes)
    end
  end

  it 'reports table, local and remote values for each table reason' do
    result = verdict({ 'laps' => row(10, 100) }, { 'laps' => row(11, 120) })
    expect(result.reasons).to eq([{ 'code' => 'id_collision', 'table' => 'laps', 'local' => 100, 'remote' => 120 }])
  end

  it 'is amber with remote-only writes since the last green check' do
    result = verdict(same, same, remote_writes: 2)
    expect(result.verdict).to eq('amber')
    expect(result.reasons).to eq([{ 'code' => 'remote_writes', 'table' => nil, 'local' => 2, 'remote' => nil }])
  end

  it 'is red with a failed script, flagging the ones that may be partially applied' do
    result = verdict(same, same, outbox: facts(failed: [['0490-a-lt4.sql', true, 9123], ['0491-b.sql', false, 9124]]))
    expect(result.verdict).to eq('red')
    expect(result.codes).to eq(%w[failed_script failed_partial])
    expect(result.reasons.first).to include('local' => '0490-a-lt4.sql', 'remote' => 9123)
  end

  it 'is red with failed SQL batches on the server not known here' do
    expect(verdict(same, same, batch_failed: 1).codes).to eq(%w[remote_batch_failed])
  end

  it 'is red when the schema versions differ' do
    result = verdict(same, same, schema_version: '20261123000000')
    expect(result.verdict).to eq('red')
    expect(result.reasons).to eq([{ 'code' => 'schema_mismatch', 'table' => nil, 'local' => schema, 'remote' => '20261123000000' }])
  end

  it 'is amber with a script deleted on the server' do
    expect(verdict(same, same, outbox: facts(missing_remote: 1)).codes).to eq(%w[missing_remote])
  end

  describe 'remote max updated_at vs the last applied script' do
    let(:later) { (applied_at + 10.minutes).utc.iso8601 }

    it 'is amber for an import-owned table updated on the server after the last applied script' do
      result = verdict({ 'meetings' => row(5, 50) }, { 'meetings' => row(5, 50, later) }, outbox: facts(last_applied_at: applied_at))
      expect(result.verdict).to eq('amber')
      expect(result.reasons.first).to include('code' => 'remote_updated', 'table' => 'meetings', 'remote' => later)
    end

    it 'ignores the user-touched tables, a time within the margin, an unknown last apply and an acknowledged time' do
      expect(verdict({ 'laps' => row(5, 50) }, { 'laps' => row(5, 50, later) }, outbox: facts(last_applied_at: applied_at)).verdict).to eq('green')
      near = (applied_at + 1.minute).utc.iso8601
      expect(verdict({ 'meetings' => row(5, 50) }, { 'meetings' => row(5, 50, near) }, outbox: facts(last_applied_at: applied_at)).verdict)
        .to eq('green')
      expect(verdict({ 'meetings' => row(5, 50) }, { 'meetings' => row(5, 50, later) }).verdict).to eq('green')
      acknowledged = described_class.call(local: side({ 'meetings' => row(5, 50) }), remote: remote({ 'meetings' => row(5, 50, later) }),
                                          outbox: facts(last_applied_at: applied_at), acknowledged_at: applied_at + 20.minutes)
      expect(acknowledged.verdict).to eq('green')
    end
  end

  it 'compares the max ids only in light mode (no count)' do
    result = verdict({ 'meetings' => { 'max_id' => 100 } }, { 'meetings' => { 'max_id' => 100 } })
    expect(result.verdict).to eq('green')
  end

  describe 'unknown' do
    %w[no_capability unreachable no_credentials unauthorized rejected error].each do |status|
      it "is unknown when the remote status is #{status}" do
        result = verdict(same, {}, status:)
        expect(result.verdict).to eq('unknown')
        expect(result.reasons).to eq([{ 'code' => status, 'table' => nil, 'local' => nil, 'remote' => 'boom' }])
      end
    end

    it 'stays red with a failed script even when the remote side is unknown' do
      result = verdict(same, {}, status: 'unreachable', outbox: facts(failed: [['0490-a.sql', true, 1]]))
      expect(result.verdict).to eq('red')
      expect(result.codes).to eq(%w[failed_script unreachable])
    end
  end

  it 'lists the red reasons first' do
    result = verdict({ 'laps' => row(10, 100), 'meetings' => row(5, 50) }, { 'laps' => row(11, 101), 'meetings' => row(4, 50) },
                     remote_writes: 1)
    expect(result.codes).to eq(%w[id_collision count_differs remote_writes])
  end

  describe Drift::Verdict::OutboxFacts do
    let(:data_root) { Pathname.new(Dir.mktmpdir) }
    let(:api_url) { 'http://localhost:8081' }

    after(:each) { FileUtils.rm_rf(data_root) }

    it 'counts the scripts of the API from the Outbox registry' do
      create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql')
      create_sql_script(data_root, 'results.sent/262/0008-c-lt4.sql', state: 'sent', target_api_url: api_url, remote_iq_id: 8)
      create_sql_script(data_root, 'results.new/262/0007-d-lt4.sql', state: 'failed', target_api_url: api_url, remote_iq_id: 7,
                                                                     single_transaction: false)
      create_sql_script(data_root, 'results.sent/262/0006-e-lt4.sql', state: 'applied', target_api_url: api_url, remote_iq_id: 6,
                                                                      resolved_at: applied_at)
      create_sql_script(data_root, 'results.sent/262/0005-f-lt4.sql', state: 'sent', target_api_url: 'http://other:447', remote_iq_id: 5)
      facts = described_class.current("#{api_url}/")
      expect(facts).to have_attributes(pending: 1, sent: 1, failed: [['0007-d-lt4.sql', false, 7]], missing_remote: 0)
      expect(facts.last_applied_at).to be_within(1.second).of(applied_at)
      expect(facts.unapplied).to eq(2)
    end

    it 'is empty with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect(described_class.current(api_url)).to eq(described_class.empty)
    ensure
      Ops::Database.reset_state!
    end
  end
end
