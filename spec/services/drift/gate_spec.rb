# frozen_string_literal: true

require 'rails_helper'

# Every scope of Drift::Gate (contract: docs/plans/contracts.md, "Drift and restore"). No network call: the stored
# check is fresh, or the API has no 'db_fingerprint' capability (a fresh check is then 'unknown' without any call).
RSpec.describe Drift::Gate do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  after(:each) { Ops::Database.reset_state! }

  def stored(*traits, **attributes)
    FactoryBot.create(:ops_db_fingerprint, *traits, api_base_url: api_url, **attributes)
  end

  traits = [nil, :amber, :unknown, :red] # (green, amber, unknown, red verdicts)

  # scope => level for [green, amber, unknown, red]
  {
    commit: %i[ok warn warn block], operation: %i[ok warn warn block], prepare: %i[ok warn warn block],
    push: %i[ok warn warn warn], board_write: %i[ok warn warn warn], rake: %i[ok warn warn block]
  }.each do |scope, levels|
    describe "scope :#{scope}" do
      traits.zip(levels).each do |trait, level|
        verdict = trait ? trait.to_s : 'green'
        it "is :#{level} on a #{verdict} verdict" do
          row = trait ? stored(trait) : stored
          result = described_class.check(scope:)
          expect(result.level).to eq(level)
          expect(result.verdict).to eq(row)
          expect(result.reasons).to all(include(:code, :table, :local, :remote))
          expect(result.allowed?).to eq(level == :ok)
          expect(described_class.check(scope:, acknowledged: true).allowed?).to eq(level != :block)
        end
      end
    end
  end

  it 'lets a red verdict through only for :rake with force' do
    stored(:red)
    expect(described_class.check(scope: :rake, force: true)).to be_allowed
    expect(described_class.check(scope: :rake, force: true).level).to eq(:block)
    expect(described_class.check(scope: :commit, force: true, acknowledged: true)).not_to be_allowed
  end

  it 'reports the reasons of the stored check with Symbol keys, plus a summary' do
    stored(:red)
    result = described_class.check(scope: :commit)
    expect(result.reasons).to eq([{ code: 'id_collision', table: 'laps', local: 100, remote: 120 }])
    expect(result.verdict_name).to eq('red')
    expect(result.summary).to include(I18n.t('db_sync.verdicts.red'), 'laps')
    expect(result.messages.first).to include('120')
  end

  it 'takes a fresh light check when the last one is older than 10 minutes (unknown without the capability, no call)' do
    old = stored(taken_at: 11.minutes.ago)
    result = described_class.check(scope: :push, tables: %w[laps])
    expect(result.verdict).not_to eq(old)
    expect(result.verdict).to have_attributes(trigger: 'gate', mode: 'light', verdict: 'unknown')
    expect(result.verdict.local['tables'].keys).to eq(%w[laps])
    expect(result.level).to eq(:warn)
    expect(APIProxy).not_to have_received(:call)
  end

  it 'takes a fresh check without any stored one, and reuses it while fresh' do
    first = described_class.check(scope: :commit).verdict
    travel(5.minutes) { expect(described_class.check(scope: :commit).verdict).to eq(first) }
    expect(Ops::DbFingerprint.count).to eq(1)
  end

  it 'warns without the ops DB' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    result = described_class.check(scope: :commit)
    expect(result).to have_attributes(level: :warn, verdict: nil)
    expect(result.reasons.pluck(:code)).to eq(%w[ops_unavailable])
    expect(described_class.check(scope: :commit, acknowledged: true)).to be_allowed
  end

  it 'warns on an unexpected error, never raising' do
    allow(Ops::DbFingerprint).to receive(:latest).and_raise(RuntimeError, 'boom')
    result = described_class.check(scope: :commit)
    expect(result.level).to eq(:warn)
    expect(result.reasons.first).to include(code: 'error', remote: 'boom')
  end

  it 'refuses an unknown scope' do
    expect { described_class.check(scope: :whatever) }.to raise_error(ArgumentError)
  end
end
