# frozen_string_literal: true

require 'rails_helper'

# 0.10.103: the automatic dismissal of the FIN change alert, and its progress lines.
RSpec.describe FedernuotoWatch::ParityCheck do
  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:tmp_dir) { Dir.mktmpdir('fin-parity-check') }
  let(:store) { FedernuotoWatch::StateStore.new(path: File.join(tmp_dir, 'state.json')) }
  let(:notifier) { instance_double(FedernuotoWatch::Notifier, clear_change: nil, broadcast_change: nil) }
  let(:change) { { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k-1', 'name' => 'Meeting 1' }] } }
  let(:notices) { FedernuotoWatch::Parity::Notices.new(without_link: [], removed: [], text_only: false) }
  let(:pending_item) do
    FedernuotoWatch::Parity::Item.new(section: 'added', row: change['added'].first, board_row: nil, fin_event_id: '1', reason: :crawling)
  end
  let(:result) { pending_result }
  let(:parity) { instance_double(FedernuotoWatch::Parity, call: result) }

  def pending_result(automation: true)
    FedernuotoWatch::Parity::Result.new(actionable: [pending_item], awaiting_calendar: [], notices:, calendar: :queued, automation:)
  end

  def reached_result(automation: true)
    FedernuotoWatch::Parity::Result.new(actionable: [pending_item.with(reason: nil)], awaiting_calendar: [], notices:, calendar: nil, automation:)
  end

  def check = described_class.call(season:, store:, notifier:, parity:)

  before(:each) { store.update { { 'digest' => 'd1', 'rows' => [], 'change' => change } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it 'does nothing without a pending change' do
    store.acknowledge!
    expect(check.status).to eq(:none)
    expect(parity).not_to have_received(:call)
  end

  it 'stores the progress and broadcasts the alert again with it, once per progress change' do
    expect(check.status).to eq(:pending)
    progress = FedernuotoWatch::Progress.read('d1')
    expect(progress).to include('calendar' => 'queued', 'actionable' => 1, 'reached' => false)
    expect(notifier).to have_received(:broadcast_change).with(change, digest: 'd1', progress:).once
    check
    expect(notifier).to have_received(:broadcast_change).once
  end

  it 'acknowledges the change once the parity is reached (automatic, guarded by the digest)' do
    allow(parity).to receive(:call).and_return(reached_result)
    expect(check.status).to eq(:acknowledged)
    expect(store.pending_change).to be_nil
    expect(notifier).to have_received(:clear_change)
    expect(Ops::Event.find_by(kind: 'fin.watch_acknowledged').data).to include('actor' => 'auto', 'reason' => 'parity')
  end

  it "acknowledges with reason 'nothing_to_crawl' when no row was actionable" do
    allow(parity).to receive(:call).and_return(FedernuotoWatch::Parity::Result.new(actionable: [], awaiting_calendar: [], notices:, calendar: nil,
                                                                                   automation: true))
    check
    expect(Ops::Event.find_by(kind: 'fin.watch_acknowledged').data).to include('reason' => 'nothing_to_crawl')
  end

  it 'never acknowledges with the automation master switch off (the operator dismisses the alert)' do
    allow(parity).to receive(:call).and_return(reached_result(automation: false))
    expect(check.status).to eq(:pending)
    expect(store.pending_change).to eq(change)
    expect(FedernuotoWatch::Progress.read('d1')).to include('automation' => false)
    expect(notifier).to have_received(:broadcast_change)
  end

  it 'broadcasts nothing while the alert is hidden (nothing actionable yet: the calendar crawl may lend links)' do
    awaiting = FedernuotoWatch::Parity::Result.new(actionable: [], awaiting_calendar: [pending_item.with(fin_event_id: nil, reason: nil)],
                                                   notices:, calendar: :running, automation: true)
    allow(parity).to receive(:call).and_return(awaiting)
    expect(check.status).to eq(:pending)
    expect(notifier).not_to have_received(:broadcast_change)
    expect(FedernuotoWatch::Progress.alert_shown?(change, FedernuotoWatch::Progress.read('d1'))).to be false
  end

  it 'never acknowledges without the ops DB' do
    allow(parity).to receive(:call).and_return(reached_result)
    allow(Ops).to receive(:available?).and_return(false)
    expect(check.status).to eq(:pending)
    expect(store.pending_change).to eq(change)
  end

  it 'shows the plain alert again when the acknowledge is refused, the parity unknown or the check failing (fail closed)' do
    FedernuotoWatch::Progress.store!('digest' => 'd1', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
    allow(parity).to receive(:call).and_return(nil)
    expect(check.status).to eq(:unknown)
    expect(FedernuotoWatch::Progress.read('d1')).to be_nil
    expect(notifier).to have_received(:broadcast_change).with(change, digest: 'd1')
    FedernuotoWatch::Progress.store!('digest' => 'd1', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
    allow(parity).to receive(:call).and_raise(RuntimeError, 'board build failed')
    expect(check.status).to eq(:error)
    expect(FedernuotoWatch::Progress.read('d1')).to be_nil
    FedernuotoWatch::Progress.store!('digest' => 'd1', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
    allow(parity).to receive(:call).and_return(reached_result)
    allow(Ops::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'locked')
    expect(check.status).to eq(:stale)
    expect(store.pending_change).to eq(change)
    expect(notifier).to have_received(:broadcast_change).with(change, digest: 'd1').exactly(3).times
  end

  it 'removes the alert from the tabs when it becomes hidden (the change stays pending)' do
    check
    awaiting = FedernuotoWatch::Parity::Result.new(actionable: [], awaiting_calendar: [pending_item.with(fin_event_id: nil, reason: nil)],
                                                   notices:, calendar: :running, automation: true)
    allow(parity).to receive(:call).and_return(awaiting)
    check
    expect(notifier).to have_received(:clear_change)
    expect(store.pending_change).to eq(change)
  end

  it 'reports a stale snapshot (the acknowledge refused) and never raises' do
    allow(parity).to receive(:call).and_return(reached_result)
    allow(store).to receive(:acknowledge!).and_return(nil)
    expect(check.status).to eq(:stale)
    allow(parity).to receive(:call).and_raise(RuntimeError, 'boom')
    expect(check.status).to eq(:error)
    allow(parity).to receive(:call).and_return(nil)
    expect(check.status).to eq(:unknown)
  end

  describe FedernuotoWatch::Progress do
    it 'serves a payload only for the snapshot of its digest' do
      described_class.store!('digest' => 'd1', 'actionable' => 2)
      expect(described_class.read('d1')).to include('actionable' => 2)
      expect(described_class.read('d2')).to be_nil
      described_class.clear!
      expect(described_class.read('d1')).to be_nil
    end

    it 'shows the alert unless the automation found nothing actionable in the change' do
      fresh = { 'automation' => true, 'actionable' => 0, 'checked_at' => 1.minute.ago.iso8601 }
      expect(described_class.alert_shown?(change, nil)).to be true
      expect(described_class.alert_shown?(change, fresh)).to be false
      expect(described_class.alert_shown?(change, fresh.merge('automation' => false))).to be true
      expect(described_class.alert_shown?(change, fresh.merge('actionable' => 1))).to be true
      expect(described_class.alert_shown?(nil, nil)).to be false
    end

    it 'shows the alert as soon as the master switch is off (a live read), whatever the payload says' do
      fresh = { 'automation' => true, 'actionable' => 0, 'checked_at' => 1.minute.ago.iso8601 }
      DataFix::Automation.store!(:enabled, false)
      expect(described_class.alert_shown?(change, fresh)).to be true
      DataFix::Automation.store!(:enabled, true)
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect(described_class.alert_shown?(change, fresh)).to be true
    end

    it 'shows the alert when the payload is older than MAX_AGE (no planner pass refreshed it)' do
      stale = { 'automation' => true, 'actionable' => 0, 'checked_at' => (described_class::MAX_AGE + 1.minute).ago.iso8601 }
      expect(described_class.alert_shown?(change, stale)).to be true
      expect(described_class.alert_shown?(change, stale.except('checked_at'))).to be true
    end

    it '.reset! drops the payload and broadcasts the plain alert once' do
      described_class.store!('digest' => 'd1', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
      expect(described_class.reset!(store:, notifier:)).to be true
      expect(notifier).to have_received(:broadcast_change).with(change, digest: 'd1')
      expect(described_class.read('d1')).to be_nil
      expect(described_class.reset!(store:, notifier:)).to be false
      expect(notifier).to have_received(:broadcast_change).once
    end
  end
end
